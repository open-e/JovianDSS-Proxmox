# Review Plan: rollback-semaphor branch

## Step 1: Primary Pass (CURRENT — task-1782057089-151c, review:step-01:primary)
Identify top-risk areas across all changed files.
**Status**: Complete — findings written to findings.md.
Top concerns:
1. Python alarm handler `args['timeout']` type bug (critical)
2. iSCSI target REST lock commented out everywhere (significant architectural gap)

## Step 2: Deep Analysis — Python iSCSI Lock Architecture (task-1782057095-b969, review:step-02:iscsi-lock)
Focus areas:
- Verify whether the Perl cluster lock truly provides full exclusion for all
  concurrent multi-node scenarios, or whether Python-side locking is still needed.
- Confirm `_alarm_handler` bug and exact fix.
- Check whether `lock.py` / `_lock()` are reachable at all (dead code audit).
- Review interaction between `_alarm_deadline` check and actual lock acquisition.

## Step 3: Synthesis + Completion
Produce final review report, close or escalate.
