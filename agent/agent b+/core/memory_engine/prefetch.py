"""Prefetch planner: WARM L1 (pinned CPU) -> GPU L2 (async H2D batch).

Given a batch of retrieved evidence sequences (as token-id lists from the agent
loop), it packs them into a pinned CPU buffer and copies them to the GPU on a
dedicated stream (non_blocking) so the transfer overlaps model compute and the
GPU only ever holds the current working set -- never the whole C:/B-Plus.
"""
import torch


class PrefetchPlanner:
    def __init__(self, device="cuda"):
        self.device = device
        self.stream = torch.cuda.Stream()

    def plan(self, sequences, pad_id=0, max_len=None):
        if not sequences:
            return torch.zeros(0, 0, dtype=torch.long, device=self.device)
        if max_len is None:
            max_len = max(len(s) for s in sequences)
        B = len(sequences)
        cpu = torch.full((B, max_len), pad_id, dtype=torch.long)
        for i, s in enumerate(sequences):
            n = min(len(s), max_len)
            if n:
                cpu[i, :n] = torch.tensor(s[:n], dtype=torch.long)
        cpu = cpu.pin_memory()  # WARM L1: pinned for fast DMA
        with torch.cuda.stream(self.stream):
            gpu = cpu.to(self.device, non_blocking=True)  # async H2D batch
        return gpu

    def sync(self):
        self.stream.synchronize()
