using System.Diagnostics;
using BPlus.Core.Algorithm;

namespace BPlus.Runtime;

public enum LoopState
{
    Idle,
    Probing,
    Scheduling,
    Applying,
    Monitoring,
    Done
}

public class AdaptiveLoop
{
    private readonly NeuroScheduler _scheduler = new();
    private readonly Stopwatch _timer = new();
    private LoopState _state = LoopState.Idle;
    private SchedulerState _currentState;
    private SchedulerAction _currentAction;
    private SchedulerState _previousState;
    private int _iteration;

    public event Action<SchedulerAction>? OnActionApplied;
    public event Action<SchedulerState>? OnSensorRead;
    public event Action<double>? OnRewardComputed;

    public void Start()
    {
        _state = LoopState.Probing;
        _timer.Start();
        _iteration = 0;
    }

    public LoopState Tick()
    {
        switch (_state)
        {
            case LoopState.Probing:
                _previousState = _currentState;
                _currentState = HardwareProbe.ReadSensors().ToSchedulerState();
                OnSensorRead?.Invoke(_currentState);
                _state = LoopState.Scheduling;
                break;

            case LoopState.Scheduling:
                _currentAction = _scheduler.SelectAction(_currentState, training: true);
                _state = LoopState.Applying;
                break;

            case LoopState.Applying:
                ApplyAction(_currentAction);
                OnActionApplied?.Invoke(_currentAction);
                _state = LoopState.Monitoring;
                break;

            case LoopState.Monitoring:
                var after = HardwareProbe.ReadSensors().ToSchedulerState();
                double reward = _scheduler.ComputeReward(_previousState, after, _currentAction);
                OnRewardComputed?.Invoke(reward);

                _scheduler.StoreTransition(
                    _previousState,
                    ActionToIndex(_currentAction),
                    reward,
                    after,
                    _iteration > 100
                );

                if (_iteration % 10 == 0)
                    _scheduler.Train();

                _iteration++;
                _state = LoopState.Probing;
                break;
        }

        return _state;
    }

    private void ApplyAction(SchedulerAction a)
    {
        HardwareControl.PinToCore(0);
        HardwareControl.SetHighPriority();
        if (a.Profile == PowerProfile.MaxPerf)
            HardwareControl.SetPowerPolicy(PowerPolicy.Performance);
        else if (a.Profile == PowerProfile.PowerSave)
            HardwareControl.SetPowerPolicy(PowerPolicy.PowerSave);
        HardwareControl.SetCpuFrequencyMHz(a.TargetFreqMHz);
    }

    private static int ActionToIndex(SchedulerAction a)
    {
        return a.Profile switch
        {
            PowerProfile.MaxPerf => 0,
            PowerProfile.Turbo => 1,
            PowerProfile.Efficient => 2,
            PowerProfile.PowerSave => 3,
            _ => 0
        };
    }

    public string GenerateReport()
    {
        var s = _currentState;
        var a = _currentAction;
        return $"""
╔══════════════════════════════════════════════╗
║            ADAPTIVE LOOP REPORT             ║
╚══════════════════════════════════════════════╝
State:      {_state}
Iteration:  {_iteration}
IPC:        {s.Ipc:F3}
Freq:       {s.FreqMHz:F0} MHz
Temp:       {s.TempC:F1} °C
Power:      {s.PowerW:F1} W
Util:       {s.CoreUtil}%
Headroom:   {s.Headroom:P1}

Action:
  Cores:  {a.TargetCores}
  Freq:   {a.TargetFreqMHz:F0} MHz
  Profile: {a.Profile}
""";
    }
}

public static class SensorExtensions
{
    public static SchedulerState ToSchedulerState(this SensorSnapshot s)
    {
        return new SchedulerState
        {
            Ipc = s.Ipc,
            FreqMHz = s.CurrentFreqMHz,
            TempC = s.CpuTempC,
            PowerW = s.PowerDrawWatts,
            CoreUtil = s.CoreUtilPercent,
            Headroom = HardwareProbe.EstimateAvailableHeadroom(s),
            RamBW = s.RamBandwidthGBs,
            L3MissRate = s.Cycles > 0 ? (double)s.L3Misses / s.Cycles : 0,
            BranchMispredictRate = s.Instructions > 0 ? (double)s.BranchMispredicts / s.Instructions : 0,
        };
    }
}
