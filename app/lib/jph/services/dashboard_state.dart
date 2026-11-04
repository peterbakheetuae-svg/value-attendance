class DashboardState {
  bool checkedIn;
  bool checkedOut;
  bool onBreak;

  /// Times from API (GS)
  String checkInTime;
  String checkOutTime;

  String breakStartTime;
  String breakEndTime;

  /// Calculated / Display
  String breakTime;
  String workTime;

  DashboardState({
    required this.checkedIn,
    required this.checkedOut,
    required this.onBreak,
    required this.checkInTime,
    required this.checkOutTime,
    required this.breakStartTime,
    required this.breakEndTime,
    required this.breakTime,
    required this.workTime,
  });

  /// الحالة الافتراضية
  factory DashboardState.empty() {
    return DashboardState(
      checkedIn: false,
      checkedOut: false,
      onBreak: false,
      checkInTime: "--:--",
      checkOutTime: "--:--",
      breakStartTime: "--:--",
      breakEndTime: "--:--",
      breakTime: "0h 0m",
      workTime: "--:--:--",
    );
  }

  /// بناء الحالة من API
  factory DashboardState.fromApi(Map<String, dynamic> json) {
    final String checkIn =
    (json["checkInTime"] ?? "--:--").toString();
    final String checkOut =
    (json["checkOutTime"] ?? "--:--").toString();

    final bool hasCheckIn = checkIn != "--:--";
    final bool hasCheckOut = checkOut != "--:--";
    final bool onBreakApi = json["onBreak"] == true;

    return DashboardState(
      checkedIn: hasCheckIn && !hasCheckOut && !onBreakApi,
      checkedOut: hasCheckOut,
      onBreak: onBreakApi,

      checkInTime: checkIn,
      checkOutTime: checkOut,

      breakStartTime:
      (json["breakStartTime"] ?? "--:--").toString(),
      breakEndTime:
      (json["breakEndTime"] ?? "--:--").toString(),

      breakTime:
      (json["breakTime"] ?? "0h 0m").toString(),

      workTime:
      (json["workTime"] ?? "--:--:--").toString(),
    );
  }

  /// نسخة معدّلة
  DashboardState copyWith({
    bool? checkedIn,
    bool? checkedOut,
    bool? onBreak,
    String? checkInTime,
    String? checkOutTime,
    String? breakStartTime,
    String? breakEndTime,
    String? breakTime,
    String? workTime,
  }) {
    return DashboardState(
      checkedIn: checkedIn ?? this.checkedIn,
      checkedOut: checkedOut ?? this.checkedOut,
      onBreak: onBreak ?? this.onBreak,
      checkInTime: checkInTime ?? this.checkInTime,
      checkOutTime: checkOutTime ?? this.checkOutTime,
      breakStartTime: breakStartTime ?? this.breakStartTime,
      breakEndTime: breakEndTime ?? this.breakEndTime,
      breakTime: breakTime ?? this.breakTime,
      workTime: workTime ?? this.workTime,
    );
  }
}