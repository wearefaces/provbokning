import 'dart:async';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'config.dart';
import 'models.dart';

/// Cookie-aware HTTP client targeting the Flask backend.
///
/// The backend identifies the visitor with a Flask session cookie that is set
/// on the first /api/billing/status call (`_current_sid()` server-side). The
/// SAME cookie carries:
///   * the BankID-authenticated Trafikverket session, and
///   * the Stripe-paid session marker.
/// Therefore we keep one persistent jar for the whole app lifetime.
class ApiClient {
  ApiClient._(this._dio);

  final Dio _dio;
  static ApiClient? _instance;

  static Future<ApiClient> instance() async {
    if (_instance != null) return _instance!;
    final jar = CookieJar(); // in-memory for now; persist later if needed
    final dio = Dio(BaseOptions(
      baseUrl: AppConfig.apiBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'application/json',
      },
      // Don't throw on non-2xx; we inspect status codes (e.g. 402 for paywall).
      validateStatus: (_) => true,
    ));
    dio.interceptors.add(CookieManager(jar));
    _instance = ApiClient._(dio);
    return _instance!;
  }

  // ── Billing ──────────────────────────────────────────────────────────────

  Future<BillingStatus> billingStatus() async {
    final r = await _dio.get('/api/billing/status');
    return BillingStatus.fromJson(r.data as Map<String, dynamic>);
  }

  /// Returns the Stripe Checkout URL the caller should open in a browser.
  Future<String> startBillingCheckout({String? email}) async {
    final r = await _dio.post('/api/billing/checkout', data: {
      if (email != null && email.isNotEmpty) 'email': email,
    });
    final data = r.data as Map<String, dynamic>;
    if (data['ok'] != true) {
      throw ApiException(data['error']?.toString() ?? 'checkout_failed');
    }
    return data['checkout_url'] as String;
  }

  // ── BankID ───────────────────────────────────────────────────────────────

  Future<bool> isAuthenticated() async {
    final r = await _dio.get('/api/auth/check');
    return (r.data as Map<String, dynamic>)['authenticated'] == true;
  }

  Future<BankIdBegin> beginBankId() async {
    final r = await _dio.post('/api/auth/begin');
    final d = r.data as Map<String, dynamic>;
    if (d['ok'] != true) {
      throw ApiException(d['error']?.toString() ?? 'bankid_begin_failed');
    }
    return BankIdBegin(
      qrCode: d['qrCode'] as String,
      autostartToken: d['autostartToken'] as String,
    );
  }

  Future<BankIdStatus> pollBankId() async {
    final r = await _dio.post('/api/auth/status');
    final d = r.data as Map<String, dynamic>;
    if (d['ok'] != true) {
      return BankIdStatus(state: 'error', error: d['error']?.toString());
    }
    return BankIdStatus(
      state: (d['status'] ?? 'pending').toString(),
      qrCode: d['qrCode']?.toString(),
    );
  }

  Future<void> logout() => _dio.post('/api/auth/logout');

  // ── Scan / Reserve ───────────────────────────────────────────────────────

  Future<ScanResult> scan() async {
    final r = await _dio.post('/api/scan');
    if (r.statusCode == 401) {
      throw ApiException('not_authenticated');
    }
    final d = r.data as Map<String, dynamic>;
    if (d['ok'] != true) {
      throw ApiException(d['error']?.toString() ?? 'scan_failed');
    }
    return ScanResult.fromJson(d);
  }

  /// Returns the reservation id, or throws [PaymentRequiredException]
  /// when the visitor is in demo mode.
  Future<String> reserve(Slot slot) async {
    final r = await _dio.post('/api/reserve', data: {'slot': slot.toJson()});
    if (r.statusCode == 402) {
      final d = r.data as Map<String, dynamic>? ?? {};
      throw PaymentRequiredException(
        d['message']?.toString() ?? 'Aktivera live-läge för att boka tider.',
      );
    }
    final d = r.data as Map<String, dynamic>;
    return (d['id'] ?? '').toString();
  }

  Future<bool> verifySlot(Slot slot) async {
    final r =
        await _dio.post('/api/verify_slot', data: {'slot': slot.toJson()});
    final d = r.data as Map<String, dynamic>? ?? {};
    return d['still_available'] == true;
  }

  // ── Config ───────────────────────────────────────────────────────────────

  Future<void> saveConfig(Map<String, dynamic> cfg) async {
    await _dio.post('/save_config', data: cfg);
  }
}

class BankIdBegin {
  final String qrCode;
  final String autostartToken;
  BankIdBegin({required this.qrCode, required this.autostartToken});
}

class BankIdStatus {
  final String state; // 'pending' | 'complete' | 'error' | 'outstandingtransaction' | ...
  final String? qrCode;
  final String? error;
  BankIdStatus({required this.state, this.qrCode, this.error});
}

class ApiException implements Exception {
  final String message;
  ApiException(this.message);
  @override
  String toString() => 'ApiException: $message';
}

class PaymentRequiredException implements Exception {
  final String message;
  PaymentRequiredException(this.message);
  @override
  String toString() => message;
}
