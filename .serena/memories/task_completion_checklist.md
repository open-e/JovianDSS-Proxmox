# Task Completion Checklist

When completing a development task on this project:

## 1. Syntax Validation
- [ ] Run `perl -c` on all modified `.pm` files
- [ ] Run `python3 -m py_compile` on all modified `.py` files

## 2. Style Compliance
- [ ] Perl: 4-space indent, 80-char lines, proper parameter unpacking
- [ ] Python: PEP8, type hints, Google docstrings
- [ ] File under 1000 lines

## 3. Architecture Compliance
- [ ] Python 3-layer pattern: CLI → Driver → REST API
- [ ] Naming transformations in Python layer only (not Perl)
- [ ] NAS volume ops use `-d` flag when dataset from export property
- [ ] Functions exported from Common.pm if called from plugins

## 4. Project Status
- [ ] Update `project-status.md` with changes made
- [ ] Follow SDD completion assessment metrics (20/40/60/80/90/100%)
- [ ] Never mark 100% without human approval

## 5. Spec Compliance
- [ ] Check changes against `spec.md`
- [ ] Never edit `spec.md`

## 6. Forbidden
- Never run `rm -Rf`
- Never mark features as "fully completed" without explicit criteria
