import 'dart:async';

import 'package:arce_ai/core/device_agents.dart';
import 'package:flutter_test/flutter_test.dart';

class _Agent implements DeviceAgent {
  _Agent(this.device);

  @override
  final AgentDevice device;
  final jobs = <String>[];

  @override
  Future<AgentResult> execute(AgentJob job) async {
    jobs.add(job.id);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    return AgentResult(jobId: job.id, deviceId: device.id, text: '${device.name}:${job.prompt}');
  }
}

AgentDevice _device(String id, {AgentTrust trust = AgentTrust.trusted, int slots = 1}) => AgentDevice(
      id: id,
      name: id,
      platform: id == 'android' ? AgentPlatform.android : AgentPlatform.linux,
      fingerprint: 'sha256:$id',
      capabilities: const {AgentCapability.textGeneration},
      maxParallelJobs: slots,
      trust: trust,
    );

void main() {
  test('distributes independent candidate jobs across trusted agents', () async {
    final first = _Agent(_device('android'));
    final second = _Agent(_device('linux'));
    final pool = DeviceAgentPool()
      ..register(first)
      ..register(second);

    final results = await pool.dispatch(const [
      AgentJob(id: 'a', prompt: 'one'),
      AgentJob(id: 'b', prompt: 'two'),
    ]);

    expect(results.every((result) => result.ok), isTrue);
    expect(first.jobs, ['a']);
    expect(second.jobs, ['b']);
  });

  test('pending devices cannot receive a job until pairing marks them trusted', () async {
    final agent = _Agent(_device('pending', trust: AgentTrust.pending));
    final pool = DeviceAgentPool()..register(agent);

    final blocked = await pool.dispatch(const [AgentJob(id: 'a', prompt: 'hello')]);
    expect(blocked.single.error, '対応する信頼済み端末がありません');

    pool.setTrust('pending', AgentTrust.trusted);
    final accepted = await pool.dispatch(const [AgentJob(id: 'b', prompt: 'hello')]);
    expect(accepted.single.deviceId, 'pending');
  });
}
