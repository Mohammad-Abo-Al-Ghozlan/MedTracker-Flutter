import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tz_init;
import 'package:timezone/timezone.dart' as tz;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tz_init.initializeTimeZones(); // Initialize timezones
  runApp(const MedicationTrackerApp());
}

class MedicationTrackerApp extends StatelessWidget {
  const MedicationTrackerApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Medication Tracker',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        visualDensity: VisualDensity.adaptivePlatformDensity,
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
  FlutterLocalNotificationsPlugin();

  List<Medication> medications = [];
  List<HealthMetric> healthMetrics = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refreshData();
    }
  }

  Future<void> _initializeApp() async {
    // Initialize notifications
    await _initializeNotifications();

    // Fetch initial data
    await _refreshData();
  }

  Future<void> _initializeNotifications() async {
    const AndroidInitializationSettings initializationSettingsAndroid =
    AndroidInitializationSettings('@mipmap/ic_launcher');

    final DarwinInitializationSettings initializationSettingsIOS =
    DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    final InitializationSettings initializationSettings = InitializationSettings(
      android: initializationSettingsAndroid,
      iOS: initializationSettingsIOS,
    );

    await flutterLocalNotificationsPlugin.initialize(
      initializationSettings,
    );
  }

  Future<void> _refreshData() async {
    setState(() {
      isLoading = true;
    });

    await Future.wait([
      _fetchMedications(),
      _fetchHealthMetrics(),
    ]);

    setState(() {
      isLoading = false;
    });
  }

  Future<void> _fetchMedications() async {
    setState(() {
      isLoading = true;
    });

    try {
      final response = await http.get(
        Uri.parse('https://www.swisslifelb.com/med/medications.php'),
      );

      if (response.statusCode == 200) {
        List<dynamic> data = json.decode(response.body);
        setState(() {
          medications = data.map((item) => Medication.fromJson(item)).toList();
          medications.sort((a, b) {
            if (a.isOverdue && !b.isOverdue) return -1;
            if (!a.isOverdue && b.isOverdue) return 1;
            return a.nextDueTime.compareTo(b.nextDueTime);
          });
        });
        _scheduleMedicationNotifications();
      } else {
        print('Failed to fetch medications: ${response.statusCode}');
        _showErrorSnackBar('Failed to fetch medications. Please try again.');
      }
    } catch (e) {
      print('Error fetching medications: $e');
      _showErrorSnackBar('Error fetching medications. Please check your connection.');
    } finally {
      setState(() {
        isLoading = false;
      });
    }
  }

  Future<void> _fetchHealthMetrics() async {
    try {
      final response = await http.get(
        Uri.parse('https://www.swisslifelb.com/med/health_metrics.php'),
      );

      if (response.statusCode == 200) {
        List<dynamic> data = json.decode(response.body);
        setState(() {
          healthMetrics = data.map((item) => HealthMetric.fromJson(item)).toList();

          // Sort health metrics by date (newest first)
          healthMetrics.sort((a, b) => b.timestamp.compareTo(a.timestamp));
        });
      } else {
        print('Failed to fetch health metrics: ${response.body}');
      }
    } catch (e) {
      print('Error fetching health metrics: $e');
    }
  }

  Future<void> _scheduleMedicationNotifications() async {
    // Cancel all existing notifications
    await flutterLocalNotificationsPlugin.cancelAll();

    // Schedule new notifications for each medication
    for (var medication in medications) {
      if (medication.nextDueTime.isAfter(DateTime.now()) && !medication.isCompleted) {
        AndroidNotificationDetails androidDetails = const AndroidNotificationDetails(
          'medication_channel',
          'Medication Reminders',
          channelDescription: 'Notifications for medication reminders',
          importance: Importance.high,
          priority: Priority.high,
        );

        DarwinNotificationDetails iosDetails = const DarwinNotificationDetails(
          presentAlert: true,
          presentBadge: true,
          presentSound: true,
        );

        NotificationDetails notificationDetails = NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
        );

        await flutterLocalNotificationsPlugin.zonedSchedule(
          medication.id.hashCode,
          'Medication Reminder',
          'Time to take ${medication.name}',
          tz.TZDateTime.from(medication.nextDueTime, tz.local),
          notificationDetails,
          uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
          matchDateTimeComponents: DateTimeComponents.time,
          androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
        );
      }
    }
  }

  Future<void> _addMedication() async {
    final result = await showDialog<Medication>(
      context: context,
      builder: (context) => AddMedicationDialog(),
    );

    if (result != null) {
      try {
        final response = await http.post(
          Uri.parse('https://www.swisslifelb.com/med/add_medication.php'),
          body: {
            'name': result.name,
            'dosage': result.dosage,
            'time': result.time,
            'repeat_type': result.repeatType,
            'custom_days': json.encode(result.customDays),
          },
        );

        if (response.statusCode == 200) {
          _refreshData();
        } else {
          _showErrorSnackBar('Failed to add medication');
        }
      } catch (e) {
        _showErrorSnackBar('Error adding medication: $e');
      }
    }
  }

  Future<void> _addHealthMetric() async {
    final result = await showDialog<HealthMetric>(
      context: context,
      builder: (context) => AddHealthMetricDialog(),
    );

    if (result != null) {
      try {
        final response = await http.post(
          Uri.parse('https://www.swisslifelb.com/med/add_health_metric.php'),
          body: {
            'type': result.type,
            'value': result.value.toString(),
            'timestamp': result.timestamp.toIso8601String(),
          },
        );

        if (response.statusCode == 200) {
          _refreshData();
        } else {
          _showErrorSnackBar('Failed to add health metric');
        }
      } catch (e) {
        _showErrorSnackBar('Error adding health metric: $e');
      }
    }
  }

  Future<void> _toggleMedicationCompletion(Medication medication) async {
    try {
      final response = await http.post(
        Uri.parse('https://www.swisslifelb.com/med/toggle_medication.php'),
        body: {
          'medication_id': medication.id.toString(),
          'completed': (!medication.isCompleted).toString(),
        },
      );

      if (response.statusCode == 200) {
        _refreshData();
      } else {
        _showErrorSnackBar('Failed to update medication status');
      }
    } catch (e) {
      _showErrorSnackBar('Error updating medication status: $e');
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Health Tracker'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Medications', icon: Icon(Icons.medication)),
              Tab(text: 'Health Metrics', icon: Icon(Icons.favorite)),
            ],
          ),
        ),
        body: isLoading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
          children: [
            _buildMedicationsTab(),
            _buildHealthMetricsTab(),
          ],
        ),
        floatingActionButton: _buildFloatingActionButton(),
      ),
    );
  }

  Widget _buildFloatingActionButton() {
    return Builder(
      builder: (context) {
        final tabIndex = DefaultTabController.of(context).index;

        return FloatingActionButton(
          onPressed: tabIndex == 0 ? _addMedication : _addHealthMetric,
          child: Icon(tabIndex == 0 ? Icons.add_circle : Icons.add_chart),
        );
      },
    );
  }

  Widget _buildMedicationsTab() {
    if (medications.isEmpty) {
      return const Center(
        child: Text('No medications added yet'),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshData,
      child: ListView.builder(
        itemCount: medications.length,
        itemBuilder: (context, index) {
          final medication = medications[index];

          return MedicationListItem(
            medication: medication,
            onToggle: _toggleMedicationCompletion,
          );
        },
      ),
    );
  }

  Widget _buildHealthMetricsTab() {
    if (healthMetrics.isEmpty) {
      return const Center(
        child: Text('No health metrics recorded yet'),
      );
    }

    return RefreshIndicator(
      onRefresh: _refreshData,
      child: ListView.builder(
        itemCount: healthMetrics.length,
        itemBuilder: (context, index) {
          final metric = healthMetrics[index];

          return HealthMetricListItem(metric: metric);
        },
      ),
    );
  }
}

class MedicationListItem extends StatelessWidget {
  final Medication medication;
  final Function(Medication) onToggle;

  const MedicationListItem({
    Key? key,
    required this.medication,
    required this.onToggle,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final timeFormat = DateFormat('h:mm a');
    final dateFormat = DateFormat('MMM d, yyyy');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: medication.isOverdue ? Colors.red.shade50 : null,
      child: ListTile(
        leading: Checkbox(
          value: medication.isCompleted,
          onChanged: (_) => onToggle(medication),
        ),
        title: Text(
          medication.name,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            decoration: medication.isCompleted ? TextDecoration.lineThrough : null,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Dosage: ${medication.dosage}'),
            Text('Next: ${timeFormat.format(medication.nextDueTime)} (${_getRepeatText(medication)})'),
            if (medication.isOverdue)
              Text(
                'OVERDUE',
                style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
              ),
          ],
        ),
        trailing: Icon(
          Icons.alarm,
          color: medication.isOverdue ? Colors.red : Colors.grey,
        ),
      ),
    );
  }

  String _getRepeatText(Medication medication) {
    switch (medication.repeatType) {
      case 'daily':
        return 'Daily';
      case 'weekly':
        return 'Weekly';
      case 'custom':
        return 'Custom';
      case 'never':
        return 'Once';
      default:
        return '';
    }
  }
}

class HealthMetricListItem extends StatelessWidget {
  final HealthMetric metric;

  const HealthMetricListItem({
    Key? key,
    required this.metric,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final dateTimeFormat = DateFormat('MMM d, yyyy - h:mm a');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: Icon(
          metric.type == 'blood_sugar' ? Icons.bloodtype : Icons.favorite,
          color: metric.type == 'blood_sugar' ? Colors.blue : Colors.red,
        ),
        title: Text(
          metric.type == 'blood_sugar' ? 'Blood Sugar: ${metric.value} mg/dL' : 'Blood Pressure: ${metric.value}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(dateTimeFormat.format(metric.timestamp)),
      ),
    );
  }
}

class AddMedicationDialog extends StatefulWidget {
  const AddMedicationDialog({Key? key}) : super(key: key);

  @override
  _AddMedicationDialogState createState() => _AddMedicationDialogState();
}

class _AddMedicationDialogState extends State<AddMedicationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _dosageController = TextEditingController();

  TimeOfDay _selectedTime = TimeOfDay.now();
  String _repeatType = 'daily';
  List<bool> _selectedDays = List.filled(7, false);

  @override
  void dispose() {
    _nameController.dispose();
    _dosageController.dispose();
    super.dispose();
  }

  Future<void> _selectTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: _selectedTime,
    );

    if (picked != null && picked != _selectedTime) {
      setState(() {
        _selectedTime = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Medication'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Medication Name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _dosageController,
                decoration: const InputDecoration(
                  labelText: 'Dosage',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a dosage';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              ListTile(
                title: const Text('Time'),
                subtitle: Text(_selectedTime.format(context)),
                trailing: const Icon(Icons.access_time),
                onTap: _selectTime,
              ),
              const SizedBox(height: 16),
              const Text('Repeat'),
              RadioListTile<String>(
                title: const Text('Daily'),
                value: 'daily',
                groupValue: _repeatType,
                onChanged: (value) {
                  setState(() {
                    _repeatType = value!;
                  });
                },
              ),
              RadioListTile<String>(
                title: const Text('Weekly'),
                value: 'weekly',
                groupValue: _repeatType,
                onChanged: (value) {
                  setState(() {
                    _repeatType = value!;
                  });
                },
              ),
              RadioListTile<String>(
                title: const Text('Custom'),
                value: 'custom',
                groupValue: _repeatType,
                onChanged: (value) {
                  setState(() {
                    _repeatType = value!;
                  });
                },
              ),
              if (_repeatType == 'custom')
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Wrap(
                    spacing: 8.0,
                    children: [
                      _buildDayChip(0, 'Mon'),
                      _buildDayChip(1, 'Tue'),
                      _buildDayChip(2, 'Wed'),
                      _buildDayChip(3, 'Thu'),
                      _buildDayChip(4, 'Fri'),
                      _buildDayChip(5, 'Sat'),
                      _buildDayChip(6, 'Sun'),
                    ],
                  ),
                ),
              RadioListTile<String>(
                title: const Text('Never (One-time)'),
                value: 'never',
                groupValue: _repeatType,
                onChanged: (value) {
                  setState(() {
                    _repeatType = value!;
                  });
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              // Create a DateTime for the next due time
              final now = DateTime.now();
              final nextDueTime = DateTime(
                now.year,
                now.month,
                now.day,
                _selectedTime.hour,
                _selectedTime.minute,
              );

              // Create a new Medication object
              final medication = Medication(
                id: 0, // Will be assigned by the backend
                name: _nameController.text,
                dosage: _dosageController.text,
                time: _selectedTime.format(context),
                nextDueTime: nextDueTime,
                repeatType: _repeatType,
                customDays: _selectedDays,
                isCompleted: false,
                isOverdue: false,
              );

              Navigator.of(context).pop(medication);
            }
          },
          child: const Text('Add'),
        ),
      ],
    );
  }

  Widget _buildDayChip(int index, String label) {
    return FilterChip(
      label: Text(label),
      selected: _selectedDays[index],
      onSelected: (selected) {
        setState(() {
          _selectedDays[index] = selected;
        });
      },
    );
  }
}

class AddHealthMetricDialog extends StatefulWidget {
  const AddHealthMetricDialog({Key? key}) : super(key: key);

  @override
  _AddHealthMetricDialogState createState() => _AddHealthMetricDialogState();
}

class _AddHealthMetricDialogState extends State<AddHealthMetricDialog> {
  final _formKey = GlobalKey<FormState>();
  final _valueController = TextEditingController();

  String _metricType = 'blood_sugar';
  DateTime _selectedDateTime = DateTime.now();

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  Future<void> _selectDateTime() async {
    final DateTime? pickedDate = await showDatePicker(
      context: context,
      initialDate: _selectedDateTime,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );

    if (pickedDate != null) {
      final TimeOfDay? pickedTime = await showTimePicker(
        context: context,
        initialTime: TimeOfDay.fromDateTime(_selectedDateTime),
      );

      if (pickedTime != null) {
        setState(() {
          _selectedDateTime = DateTime(
            pickedDate.year,
            pickedDate.month,
            pickedDate.day,
            pickedTime.hour,
            pickedTime.minute,
          );
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateTimeFormat = DateFormat('MMM d, yyyy - h:mm a');

    return AlertDialog(
      title: const Text('Add Health Metric'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(
                    value: 'blood_sugar',
                    label: Text('Blood Sugar'),
                    icon: Icon(Icons.bloodtype),
                  ),
                  ButtonSegment(
                    value: 'blood_pressure',
                    label: Text('Blood Pressure'),
                    icon: Icon(Icons.favorite),
                  ),
                ],
                selected: {_metricType},
                onSelectionChanged: (Set<String> selection) {
                  setState(() {
                    _metricType = selection.first;
                  });
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _valueController,
                decoration: InputDecoration(
                  labelText: _metricType == 'blood_sugar'
                      ? 'Blood Sugar (mg/dL)'
                      : 'Blood Pressure (systolic/diastolic)',
                  hintText: _metricType == 'blood_sugar' ? '120' : '120/80',
                  border: const OutlineInputBorder(),
                ),
                keyboardType: TextInputType.text,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter a value';
                  }

                  if (_metricType == 'blood_sugar') {
                    if (double.tryParse(value) == null) {
                      return 'Please enter a valid number';
                    }
                  } else {
                    if (!value.contains('/')) {
                      return 'Please use format: systolic/diastolic';
                    }
                  }

                  return null;
                },
              ),
              const SizedBox(height: 16),
              ListTile(
                title: const Text('Date & Time'),
                subtitle: Text(dateTimeFormat.format(_selectedDateTime)),
                trailing: const Icon(Icons.calendar_today),
                onTap: _selectDateTime,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              // Create a new HealthMetric object
              final healthMetric = HealthMetric(
                id: 0, // Will be assigned by the backend
                type: _metricType,
                value: _valueController.text,
                timestamp: _selectedDateTime,
              );

              Navigator.of(context).pop(healthMetric);
            }
          },
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class Medication {
  final int id;
  final String name;
  final String dosage;
  final String time;
  final DateTime nextDueTime;
  final String repeatType;
  final List<bool> customDays;
  final bool isCompleted;
  final bool isOverdue;

  Medication({
    required this.id,
    required this.name,
    required this.dosage,
    required this.time,
    required this.nextDueTime,
    required this.repeatType,
    required this.customDays,
    required this.isCompleted,
    required this.isOverdue,
  });

  factory Medication.fromJson(Map<String, dynamic> json) {
    return Medication(
      id: json['id'],
      name: json['name'],
      dosage: json['dosage'],
      time: json['time'],
      nextDueTime: DateTime.parse(json['next_due_time']),
      repeatType: json['repeat_type'],
      customDays: List<bool>.from(json['custom_days']),
      isCompleted: json['is_completed'] == 1,
      isOverdue: json['is_overdue'] == 1,
    );
  }
}

class HealthMetric {
  final int id;
  final String type;
  final String value;
  final DateTime timestamp;

  HealthMetric({
    required this.id,
    required this.type,
    required this.value,
    required this.timestamp,
  });

  factory HealthMetric.fromJson(Map<String, dynamic> json) {
    return HealthMetric(
      id: json['id'],
      type: json['type'],
      value: json['value'],
      timestamp: DateTime.parse(json['timestamp']),
    );
  }
}