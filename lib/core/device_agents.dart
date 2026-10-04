import 'dart:async';

/// Operations a paired ARCE.AI device may offer. The coordinator sends a job only to an agent
/// that explicitly advertises every required capability; a generic network connection is never
/// treated as permission to run code or access files.
enum AgentCapability { textGeneration, imageGeneration, videoAnalysis, webSearch, codeExecution }

enum AgentPlatform { android, windows, linux }

enum AgentTrust { pending, trusted, revoked }

class AgentDevice {
  const AgentDevice({
    required this.id,
    required this.name,
    required this.platform,
    required this.fingerprint,
    required this.capabilities,
    this.maxParallelJobs = 1,
    this.trust = AgentTrust.pending,
  });

  final String id;
  final String name;
  final AgentPlatform platform;

  /// A displayed key fingerprint. Pairing code verifies this before a device becomes trusted.
  final String fingerprint;
  final Set<AgentCapability> capabilities;
  final int maxParallelJobs;
  final AgentTrust trust;

  bool supports(Set<AgentCapability> required) => trust == AgentTrust.trusted && capabilities.containsAll(required);

  AgentDevice copyWith({AgentTrust? trust, int? maxParallelJobs}) => AgentDevice(
        id: id,
        name: name,
        platform: platform,
        fingerprint: fingerprint,
        capabilities: capabilities,
        maxParallelJobs: maxParallelJobs ?? this.maxParallelJobs,
        trust: trust ?? this.trust,
      );
}

class AgentJob {
  const AgentJob({
    required this.id,
    required this.prompt,
    this.requiredCapabilities = const {AgentCapability.textGeneration},
    this.maxTokens = 2048,
  });

  final String id;
  final String prompt;
  final Set<AgentCapability> requiredCapabilities;
  final int maxTokens;
}

class AgentResult {
  const AgentResult({required this.jobId, required this.deviceId, required this.text, this.error});

  final String jobId;
  final String deviceId;
  final String text;
  final String? error;
  bool get ok => error == null;
}

/// A transport boundary: LAN discovery, QR pairing, TLS and foreground-service lifetime belong
/// below this interface. The scheduler can therefore be tested without opening an unauthenticated
/// listening socket in the app process.
abstract interface class DeviceAgent {
  AgentDevice get device;
  Future<AgentResult> execute(AgentJob job);
}

/// Scheduler for trusted, explicitly paired device agents. It distributes independent jobs (for
/// example several candidate replies) rather than splitting one token stream across Wi-Fi.
class DeviceAgentPool {
  final Map<String, DeviceAgent> _agents = {};
  final Map<String, int> _inFlight = {};

  List<AgentDevice> get devices => [for (final agent in _agents.values) agent.device];

  void register(DeviceAgent agent) {
    _agents[agent.device.id] = agent;
  }

  void remove(String deviceId) {
    _agents.remove(deviceId);
    _inFlight.remove(deviceId);
  }

  /// Changes trust without retaining any pairing secret in this in-memory scheduler. Persistent
  /// encrypted pairing records are owned by the platform service.
  void setTrust(String deviceId, AgentTrust trust) {
    final agent = _agents[deviceId];
    if (agent == null) return;
    _agents[deviceId] = _TrustOverrideAgent(agent, agent.device.copyWith(trust: trust));
  }

  /// Runs all jobs concurrently when enough trusted agents are available. Jobs are assigned to
  /// the least busy eligible device and wait for a slot if every device is at its declared limit.
  Future<List<AgentResult>> dispatch(Iterable<AgentJob> jobs) async {
    final futures = <Future<AgentResult>>[];
    for (final job in jobs) {
      futures.add(_dispatchOne(job));
    }
    return Future.wait(futures);
  }

  Future<AgentResult> _dispatchOne(AgentJob job) async {
    while (true) {
      final eligible = _agents.values.where((agent) => agent.device.supports(job.requiredCapabilities)).toList()
        ..sort((a, b) {
          final load = (_inFlight[a.device.id] ?? 0).compareTo(_inFlight[b.device.id] ?? 0);
          return load != 0 ? load : a.device.id.compareTo(b.device.id);
        });
      if (eligible.isEmpty) {
        return AgentResult(jobId: job.id, deviceId: '', text: '', error: '対応する信頼済み端末がありません');
      }
      final selected = eligible.firstWhere(
        (agent) => (_inFlight[agent.device.id] ?? 0) < agent.device.maxParallelJobs.clamp(1, 8),
        orElse: () => eligible.first,
      );
      final active = _inFlight[selected.device.id] ?? 0;
      if (active >= selected.device.maxParallelJobs.clamp(1, 8)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        continue;
      }
      _inFlight[selected.device.id] = active + 1;
      try {
        return await selected.execute(job);
      } catch (e) {
        return AgentResult(jobId: job.id, deviceId: selected.device.id, text: '', error: '$e');
      } finally {
        _inFlight[selected.device.id] = (_inFlight[selected.device.id] ?? 1) - 1;
      }
    }
  }
}

class _TrustOverrideAgent implements DeviceAgent {
  const _TrustOverrideAgent(this._delegate, this.device);

  final DeviceAgent _delegate;
  @override
  final AgentDevice device;

  @override
  Future<AgentResult> execute(AgentJob job) => _delegate.execute(job);
}
