import 'dart:async';
import 'package:dio/dio.dart';
import 'config.dart';
import 'models.dart';
import 'api_platform_io.dart'
    if (dart.library.html) 'api_platform_web.dart';

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
    await configurePlatform(dio);
    _instance = ApiClient._(dio);
    return _instance!;
  }

  // ── Billing ──────────────────────────────────────────────────────────────

  Future<BillingStatus> billingStatus() async {
    if (AppConfig.devPaid) {
      return BillingStatus(paid: true, demo: false, stripeEnabled: false, priceLabel: '');
    }
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

  /// Tell the backend to mark the current Flask session as paid based on a
  /// completed App Store / Play Store IAP. Receipt verification happens
  /// server-side.
  Future<void> iapUnlock({
    required String platform,
    required String productId,
    required String receipt,
    required String transactionId,
  }) async {
    final r = await _dio.post('/api/billing/iap_unlock', data: {
      'platform': platform,
      'product_id': productId,
      'receipt': receipt,
      'transaction_id': transactionId,
    });
    final data = r.data as Map<String, dynamic>;
    if (data['ok'] != true) {
      throw ApiException(data['error']?.toString() ?? 'iap_unlock_failed');
    }
  }

  // ── Profile ──────────────────────────────────────────────────────────────

  Future<UserProfile> getProfile() async {
    final r = await _dio.get('/api/profile');
    if (r.data is! Map) return const UserProfile();
    return UserProfile.fromJson(r.data as Map<String, dynamic>);
  }

  /// Save the visitor's email/name on the server. If [email] matches a
  /// paid record (e.g. a Stripe purchase done on the web), the backend
  /// auto-links the paid status onto the current mobile session and the
  /// returned [BillingStatus] will reflect `paid: true`.
  Future<BillingStatus> saveProfile({String? email, String? name}) async {
    final r = await _dio.post('/api/profile', data: {
      if (email != null) 'email': email,
      if (name != null) 'name': name,
    });
    final d = (r.data as Map?)?.cast<String, dynamic>() ?? {};
    return BillingStatus(
      paid: d['paid'] == true,
      demo: d['paid'] != true,
      stripeEnabled: false, // unknown here; caller can refresh status if needed
      priceLabel: '',
      paidUntil: d['paid_until']?.toString(),
      source: (d['source'] ?? '').toString(),
      email: (d['email'] ?? '').toString(),
    );
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

  /// App Store review login: exchanges the demo code for a reviewer session
  /// (sample data, no BankID). Throws [ApiException] on an invalid code.
  Future<void> demoLogin(String code) async {
    final r = await _dio.post('/api/auth/demo_login', data: {'code': code});
    final d = (r.data as Map?)?.cast<String, dynamic>() ?? {};
    if (d['ok'] != true) {
      throw ApiException(d['error']?.toString() ?? 'invalid_code');
    }
  }

  Future<void> logout() => _dio.post('/api/auth/logout');

  // ── Scan / Reserve ───────────────────────────────────────────────────────

  Future<ScanResult> scan() async {
    // A full scan walks many Trafikverket locations server-side and can
    // easily exceed the default 30 s receive timeout. Give it plenty of
    // headroom so we don't surface a confusing Dio timeout to the user.
    final r = await _dio.post(
      '/api/scan',
      options: Options(
        sendTimeout: const Duration(minutes: 2),
        receiveTimeout: const Duration(minutes: 2),
      ),
    );
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

  // ── Background watching ──────────────────────────────────────────────────

  /// Current server-side watch state for this user.
  Future<WatchStatus> watchStatus() async {
    final r = await _dio.get('/api/watch');
    if (r.data is! Map) return WatchStatus.off();
    return WatchStatus.fromJson(r.data as Map<String, dynamic>);
  }

  /// Turn server-side watching on/off. With it on the server keeps scanning
  /// after the app is closed and the phone is locked, and notifies by SMS.
  Future<WatchStatus> setWatch({
    required bool enabled,
    int? intervalSeconds,
  }) async {
    final r = await _dio.post('/api/watch', data: {
      'enabled': enabled,
      if (intervalSeconds != null) 'interval_seconds': intervalSeconds,
    });
    if (r.statusCode == 401) throw ApiException('not_authenticated');
    if (r.data is! Map) return WatchStatus.off();
    return WatchStatus.fromJson(r.data as Map<String, dynamic>);
  }

  // ── Config ───────────────────────────────────────────────────────────────

  Future<AppConfigData> getConfig() async {
    final r = await _dio.get('/api/config');
    if (r.data is! Map) return AppConfigData.empty();
    return AppConfigData.fromJson(r.data as Map<String, dynamic>);
  }

  Future<void> saveConfig(Map<String, dynamic> cfg) async {
    await _dio.post('/save_config', data: cfg);
  }

  // ── Locations ────────────────────────────────────────────────────────────

  Future<List<LocationDetail>> locationDetails() async {
    final r = await _dio.get('/api/location_details');
    final list = (r.data as List? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(LocationDetail.fromJson)
        .toList();
  }

  // ── Activity log ─────────────────────────────────────────────────────────

  Future<List<ActivityEntry>> activityLog() async {
    final r = await _dio.get('/api/activity_log');
    final list = (r.data as List? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(ActivityEntry.fromJson)
        .toList();
  }

  // ── Reservations ─────────────────────────────────────────────────────────

  /// Active 15-minute holds the user has placed but not yet dismissed/booked.
  Future<List<Reservation>> activeReservations() async {
    final r = await _dio.get('/api/reservations');
    final list = (r.data as List? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map(Reservation.fromJson)
        .toList();
  }

  /// Update reservation status. `status` is "booked" or "dismissed".
  Future<void> updateReservation(String id, String status) async {
    await _dio.patch('/api/reservation/$id', data: {'status': status});
  }

  // ── Public subscribe (passive notifications) ─────────────────────────────

  Future<bool> subscribe({String? phone, String? email, String? name}) async {
    final r = await _dio.post('/api/subscribe', data: {
      if (phone != null && phone.isNotEmpty) 'phone': phone,
      if (email != null && email.isNotEmpty) 'email': email,
      if (name != null && name.isNotEmpty) 'name': name,
    });
    final d = r.data as Map<String, dynamic>? ?? {};
    if (d['ok'] == true) {
      final url = d['checkout_url']?.toString();
      if (url != null && url.isNotEmpty) {
        // Caller should open this URL externally.
        throw CheckoutRedirect(url);
      }
      return true;
    }
    throw ApiException(d['error']?.toString() ?? 'subscribe_failed');
  }
}

/// Signal that a Stripe Checkout URL should be opened externally by the caller.
class CheckoutRedirect implements Exception {
  final String url;
  CheckoutRedirect(this.url);
  @override
  String toString() => 'CheckoutRedirect($url)';
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
