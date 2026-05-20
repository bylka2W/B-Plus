using System.Text;

namespace BPlusTranspiler.Algorithm;

public enum MpiRankState { Idle, Working, Barrier, Reduced, Done }
public enum CollectiveOp { Reduce, AllReduce, Broadcast, Scatter, Gather, AllGather }

public class MpiClusterConfig
{
    public int WorldSize { get; set; } = 1;
    public int LocalRank { get; set; } = 0;
    public string Hostfile { get; set; } = "";
    public int LocalSize { get; set; } = 1;
    public int NumaNodes { get; set; } = 1;
}

public class MpiRank
{
    public int Rank { get; set; }
    public MpiRankState State { get; set; } = MpiRankState.Idle;
    public Dictionary<string, byte[]> Buffers { get; } = new();
    public List<double> LocalGradients { get; } = new();
    public double SyncTime { get; set; }
    public int CommittedOps { get; set; }
}

public class MpiJobScheduler
{
    readonly MpiClusterConfig _config;
    readonly MpiRank[] _ranks;
    readonly Queue<string> _taskQueue = new();

    public MpiClusterConfig Config => _config;
    public MpiRank[] Ranks => _ranks;

    public MpiJobScheduler(MpiClusterConfig config)
    {
        _config = config;
        _ranks = new MpiRank[config.WorldSize];
        for (int i = 0; i < config.WorldSize; i++)
            _ranks[i] = new MpiRank { Rank = i };
    }

    public void EnqueueTask(string task)
    {
        _taskQueue.Enqueue(task);
    }

    public void EnqueueDataParallel(string formula, int chunkSize)
    {
        for (int i = 0; i < _config.WorldSize; i++)
            EnqueueTask($"data_parallel:{formula}:{chunkSize}:rank:{i}");
    }

    public void Broadcast(string varName, byte[] data)
    {
        foreach (var r in _ranks) r.State = MpiRankState.Working;
        int chunkSize = data.Length / _config.WorldSize;
        for (int i = 0; i < _config.WorldSize; i++)
        {
            var offset = i * chunkSize;
            var size = i == _config.WorldSize - 1 ? data.Length - offset : chunkSize;
            var slice = new byte[size];
            Array.Copy(data, offset, slice, 0, size);
            _ranks[i].Buffers[varName] = slice;
            _ranks[i].State = MpiRankState.Idle;
        }
    }

    public void Reduce(string varName, CollectiveOp op)
    {
        foreach (var r in _ranks) r.State = MpiRankState.Barrier;
        if (op == CollectiveOp.Reduce)
        {
            double result = 0;
            foreach (var r in _ranks)
            {
                if (r.LocalGradients.Count > 0)
                    result = op switch
                    {
                        CollectiveOp.Reduce when r.LocalGradients.Count > 0 =>
                            r.LocalGradients.Sum(),
                        _ => result
                    };
            }
            _ranks[0].Buffers[varName] = BitConverter.GetBytes(result);
        }
        foreach (var r in _ranks) r.State = MpiRankState.Idle;
    }

    public void AllReduce(string varName, CollectiveOp op)
    {
        Reduce(varName, op);
        Broadcast(varName, _ranks[0].Buffers[varName]);
    }

    public void Barrier()
    {
        foreach (var r in _ranks) { r.State = MpiRankState.Barrier; r.SyncTime = 0; }
        int done = 0;
        while (done < _config.WorldSize)
        {
            done = 0;
            foreach (var r in _ranks)
                if (r.State == MpiRankState.Idle || r.State == MpiRankState.Done)
                    done++;
        }
        foreach (var r in _ranks) r.State = MpiRankState.Idle;
    }

    public string GenerateSlurmScript(int nodes, int ppn, int ntasks)
    {
        var sb = new StringBuilder();
        sb.AppendLine("#!/bin/bash");
        sb.AppendLine("#SBATCH --job-name=bplus_mpi");
        sb.AppendLine($"#SBATCH --nodes={nodes}");
        sb.AppendLine($"#SBATCH --ntasks={ntasks}");
        sb.AppendLine($"#SBATCH --ntasks-per-node={ppn}");
        sb.AppendLine("#SBATCH --time=24:00:00");
        sb.AppendLine("#SBATCH --partition=default");
        sb.AppendLine("module load openmpi");
        sb.AppendLine("srun ./bplus_worker");
        return sb.ToString();
    }

    public string GenerateMpiConfig()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"world_size={_config.WorldSize}");
        sb.AppendLine($"local_size={_config.LocalSize}");
        sb.AppendLine($"numa_nodes={_config.NumaNodes}");
        if (!string.IsNullOrEmpty(_config.Hostfile))
            sb.AppendLine($"hostfile={_config.Hostfile}");
        return sb.ToString();
    }

    public string ScheduleTask()
    {
        if (_taskQueue.Count == 0) return "";
        var task = _taskQueue.Dequeue();
        int rank = _ranks.Where(r => r.State == MpiRankState.Idle).FirstOrDefault()?.Rank ?? 0;
        return $"rank:{rank}:{task}";
    }

    public int ActiveRanks => _ranks.Count(r => r.State == MpiRankState.Working);
    public double AvgSyncTime => _ranks.Length > 0 ? _ranks.Average(r => r.SyncTime) : 0;
    public int TotalCommittedOps => _ranks.Sum(r => r.CommittedOps);
}

public class DistributedMatrix
{
    readonly MpiJobScheduler _mpi;
    readonly int _rows, _cols, _rowChunk;

    public DistributedMatrix(MpiJobScheduler mpi, int rows, int cols)
    {
        _mpi = mpi;
        _rows = rows;
        _cols = cols;
        _rowChunk = rows / mpi.Config.WorldSize;
    }

    public void MatMul(byte[] A, byte[] B, byte[] C, int aRows, int aCols, int bCols)
    {
        _mpi.EnqueueDataParallel("mat_mul", aCols / _mpi.Config.WorldSize);
        _mpi.Barrier();
    }

    public void AllReduce(double[] gradient)
    {
        var buf = new byte[gradient.Length * 8];
        Buffer.BlockCopy(gradient, 0, buf, 0, buf.Length);
        _mpi.AllReduce("gradient", CollectiveOp.AllReduce);
    }

    public string Diagnostic()
    {
        var sb = new StringBuilder();
        sb.AppendLine($"DistributedMatrix: {_rows}x{_cols}");
        sb.AppendLine($"Chunk per rank: {_rowChunk}");
        sb.AppendLine($"Active ranks: {_mpi.ActiveRanks}/{_mpi.Config.WorldSize}");
        sb.AppendLine($"Avg sync time: {_mpi.AvgSyncTime:F2}ms");
        sb.AppendLine($"Total ops: {_mpi.TotalCommittedOps}");
        return sb.ToString();
    }
}