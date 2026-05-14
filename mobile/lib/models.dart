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
