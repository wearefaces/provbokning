/// Strongly-typed wrappers around the JSON shapes returned by the backend.
class Slot {
  final String date;
  final String time;
  final String location;
  final int? locationId;
  final String name;
  final String cost;
  final String occasionId;

  Slot({
    required this.date,
    required this.time,
    required this.location,
    this.locationId,
    this.name = '',
    this.cost = '',
    this.occasionId = '',
  });

  factory Slot.fromJson(Map<String, dynamic> j) => Slot(
        date: (j['date'] ?? '').toString(),
        time: (j['time'] ?? '').toString(),
        location: (j['location'] ?? '').toString(),
        locationId: j['location_id'] is int
            ? j['location_id'] as int
            : int.tryParse('${j['location_id']}'),
        name: (j['name'] ?? '').toString(),
        cost: (j['cost'] ?? '').toString(),
        occasionId: (j['occasion_id'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'date': date,
        'time': time,
        'location': location,
        'location_id': locationId,
        'name': name,
        'cost': cost,
        'occasion_id': occasionId,
      };

  String get key => '$date|$time|$location|$name';
}

class BillingStatus {
  final bool paid;
  final bool demo;
  final bool stripeEnabled;
  final String priceLabel;
  final String? paidUntil;

  BillingStatus({
    required this.paid,
    required this.demo,
    required this.stripeEnabled,
    required this.priceLabel,
    this.paidUntil,
  });

  factory BillingStatus.fromJson(Map<String, dynamic> j) => BillingStatus(
        paid: j['paid'] == true,
        demo: j['demo'] == true,
        stripeEnabled: j['stripe_enabled'] == true,
        priceLabel: (j['price_label'] ?? '').toString(),
        paidUntil: j['paid_until']?.toString(),
      );
}

class ScanResult {
  final List<Slot> times;
  final List<Slot> added;
  final List<Slot> removed;

  ScanResult({required this.times, required this.added, required this.removed});

  factory ScanResult.fromJson(Map<String, dynamic> j) {
    List<Slot> parse(dynamic l) => (l as List? ?? const [])
        .map((e) => Slot.fromJson(e as Map<String, dynamic>))
        .toList();
    return ScanResult(
      times: parse(j['times']),
      added: parse(j['added']),
      removed: parse(j['removed']),
    );
  }
}

class AppConfigData {
  final String swedishSsn;
  final String licenceType; // B, A, A1, A2
  final String examType; // Körprov, Kunskapsprov
  final List<String> locations;
  final String dateFrom;
  final String dateTo;
  final bool smsEnabled;
  final String smsTo;

  AppConfigData({
    required this.swedishSsn,
    required this.licenceType,
    required this.examType,
    required this.locations,
    required this.dateFrom,
    required this.dateTo,
    required this.smsEnabled,
    required this.smsTo,
  });

  factory AppConfigData.empty() => AppConfigData(
        swedishSsn: '',
        licenceType: 'B',
        examType: 'Körprov',
        locations: const [],
        dateFrom: '',
        dateTo: '',
        smsEnabled: false,
        smsTo: '',
      );

  factory AppConfigData.fromJson(Map<String, dynamic> j) => AppConfigData(
        swedishSsn: (j['swedish_ssn'] ?? '').toString(),
        licenceType: (j['licence_type'] ?? 'B').toString(),
        examType: (j['exam_type'] ?? 'Körprov').toString(),
        locations: (j['locations'] as List? ?? const [])
            .map((e) => e.toString())
            .toList(),
        dateFrom: (j['date_from'] ?? '').toString(),
        dateTo: (j['date_to'] ?? '').toString(),
        smsEnabled: j['sms_enabled'] == true,
        smsTo: (j['sms_to'] ?? '').toString(),
      );

  Map<String, dynamic> toJson() => {
        'swedish_ssn': swedishSsn,
        'licence_type': licenceType,
        'exam_type': examType,
        'locations': locations,
        'date_from': dateFrom,
        'date_to': dateTo,
        'sms_enabled': smsEnabled,
        'sms_to': smsTo,
      };

  AppConfigData copyWith({
    String? swedishSsn,
    String? licenceType,
    String? examType,
    List<String>? locations,
    String? dateFrom,
    String? dateTo,
    bool? smsEnabled,
    String? smsTo,
  }) =>
      AppConfigData(
        swedishSsn: swedishSsn ?? this.swedishSsn,
        licenceType: licenceType ?? this.licenceType,
        examType: examType ?? this.examType,
        locations: locations ?? this.locations,
        dateFrom: dateFrom ?? this.dateFrom,
        dateTo: dateTo ?? this.dateTo,
        smsEnabled: smsEnabled ?? this.smsEnabled,
        smsTo: smsTo ?? this.smsTo,
      );
}

class LocationDetail {
  final int id;
  final String name;
  final String region;

  LocationDetail({required this.id, required this.name, required this.region});

  factory LocationDetail.fromJson(Map<String, dynamic> j) => LocationDetail(
        id: (j['id'] is int) ? j['id'] as int : int.tryParse('${j['id']}') ?? 0,
        name: (j['name'] ?? '').toString(),
        region: (j['region'] ?? '').toString(),
      );
}

class ActivityEntry {
  final String type;
  final String time;
  final Map<String, dynamic> raw;

  ActivityEntry({required this.type, required this.time, required this.raw});

  factory ActivityEntry.fromJson(Map<String, dynamic> j) => ActivityEntry(
        type: (j['type'] ?? '').toString(),
        time: (j['time'] ?? '').toString(),
        raw: j,
      );
}
