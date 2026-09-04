"""Trafikverket Booking API client.

Communicates with https://fp.trafikverket.se/Boka/occasion-bundles
to retrieve available driving test times.
"""

import requests
from user_agent import generate_user_agent


LICENCE_TYPES = {
    "B": {"licence_id": 5, "vehicle_type_id": 2, "exam_ids": {"Körprov": 12, "Kunskapsprov": 3}},
    "A": {"licence_id": 4, "vehicle_type_id": 1, "exam_ids": {"Körprov": 10, "Kunskapsprov": 2}},
    "A1": {"licence_id": 2, "vehicle_type_id": 1, "exam_ids": {"Körprov": 10, "Kunskapsprov": 2}},
    "A2": {"licence_id": 24, "vehicle_type_id": 1, "exam_ids": {"Körprov": 10, "Kunskapsprov": 2}},
    # Moped klass I (AM) — knowledge test only. IDs unverified; see web.py.
    "AM": {"licence_id": 1, "vehicle_type_id": 3, "exam_ids": {"Kunskapsprov": 3}},
}

# Backwards-compatible flat mapping (for legacy configs without licence_type)
EXAMINATION_TYPES = {
    "Körprov": 12,
    "Kunskapsprov": 3,
}


class TrafikverketAPI:
    BASE_URL = "https://fp.trafikverket.se/Boka"

    def __init__(self, ssn: str, examination_type: str = "Körprov", licence_type: str = "B"):
        self.ssn = ssn
        lt = LICENCE_TYPES.get(licence_type, LICENCE_TYPES["B"])
        self.licence_id = lt["licence_id"]
        self.vehicle_type_id = lt["vehicle_type_id"]
        self.examination_type_id = lt["exam_ids"].get(examination_type, EXAMINATION_TYPES.get(examination_type, 12))
        self.session = requests.Session()
        self.session.headers.update({
            "Accept": "application/json, text/javascript, */*; q=0.01",
            "Content-Type": "application/json",
            "X-Requested-With": "XMLHttpRequest",
            "Origin": "https://fp.trafikverket.se",
            "Referer": "https://fp.trafikverket.se/Boka/",
            "User-Agent": generate_user_agent(),
        })

    def _build_params(self, location_id: int) -> dict:
        return {
            "bookingSession": {
                "socialSecurityNumber": self.ssn,
                "licenceId": self.licence_id,
                "bookingModeId": 0,
                "ignoreDebt": False,
                "ignoreBookingHindrance": False,
                "examinationTypeId": self.examination_type_id,
                "excludeExaminationCategories": [],
                "rescheduleTypeId": 0,
                "paymentIsActive": False,
                "paymentReference": None,
                "paymentUrl": None,
                "searchedMonths": 0,
            },
            "occasionBundleQuery": {
                "startDate": "1970-01-01T00:00:00.000Z",
                "searchedMonths": 0,
                "locationId": location_id,
                "nearbyLocationIds": [],
                "vehicleTypeId": self.vehicle_type_id,
                "tachographTypeId": 1,
                "occasionChoiceId": 1,
                "examinationTypeId": self.examination_type_id,
            },
        }

    def get_available_times(self, location_id: int) -> list[dict]:
        """Fetch available booking times for a specific location.

        Returns a list of dicts with keys:
            date, time, location, name, cost, occasion_id
        """
        params = self._build_params(location_id)
        resp = self.session.post(
            f"{self.BASE_URL}/occasion-bundles",
            json=params,
            timeout=30,
        )
        resp.raise_for_status()

        data = resp.json()
        if data.get("status") != 200:
            return []

        bundles = data.get("data", {}).get("bundles", [])
        results = []
        for bundle in bundles:
            for occasion in bundle.get("occasions", []):
                results.append({
                    "date": occasion.get("date"),
                    "time": occasion.get("time"),
                    "location": occasion.get("locationName"),
                    "name": occasion.get("name"),
                    "cost": occasion.get("cost"),
                    "occasion_id": occasion.get("occasionId"),
                })
        return results
