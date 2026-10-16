# GitHub Copilot instructions — VideotecaMac

**Mandatory first read:** [AGENTS.md](../AGENTS.md), then [README.md](../README.md) and only the related `Sources/` files. AGENTS.md is the authoritative AI engineering policy (antirez-inspired): reject unnecessary code, own a human-explainable system model, test integration paths, and protect hard-to-reverse choices.

Before implementation state what the change will NOT do, affected filesystem side effects and the smallest reversible solution. Never test on real media collections; use synthetic paths and disposable copies, failure/undo cases, and macOS verification where possible. Do not commit paths, media metadata or credentials. Report untested platforms explicitly; do not claim a successful Xcode build without running it.
