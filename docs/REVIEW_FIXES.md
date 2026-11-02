# Review fixes

This document records source changes and verification for the pasted review and its follow-up. The following choices are deliberate:

- Limits recreation warns that the existing container and VM logs are deleted. It does not attempt to merge old and replacement log files.
- Bundles are signed ad hoc and checked with `codesign --verify --deep --strict`. They are not Developer ID signed or notarized, and Gatekeeper trust is not established by this check.
- Destructive runtime integration checks require a dedicated runtime and remain opt-in. Local regression tests use fixtures.

| Finding | Resulting behavior |
| --- | --- |
| Compose Down target and confirmation | Uses a snapshot of the saved project name, file and network option; the confirmation identifies both project and full file path. |
| Compose options crossing projects | Resets Up and Down options when the selected project changes. |
| Builds and Kubernetes work cancelled by navigation | Build operations live in AppStore; page disappearance no longer cancels either operation. Kubernetes cancellation remains available after returning to the page. |
| Invalid release signature and missing versions | The build script records app/build versions, signs after staging all resources, and performs strict verification. Release versions come from the tag. |
| Limits recreation loses logs | The review and required acknowledgement explicitly describe log deletion. |
| Inspect/Logs refresh race | Captures tab and resource identity, cancels manual refresh tasks, and checks resource, tab, token and cancellation before publishing. Inspect redaction uses the captured tab. |
| Quit leaves children behind or cancels logout | Uses terminateLater and replies when shutdown finishes. Waits for limits recovery, cancels tracked operations/polling, closes terminal sessions, shuts down MLX, and drains the process registry. |
| Unchanged CLI path resets runtime | Normalizes empty paths and returns before resetting an unchanged path; redundant Settings buttons are disabled. |
| Optional stats counters | Omits unavailable samples while retaining healthy containers' samples; malformed counters still fail decoding. |
| Double-quoted command escapes | Retains backslashes before non-shell-special characters such as the `d` in `grep "\d+"`. |
| Unicode text loss | Filters controls by scalar while preserving zero-width joiners/non-joiners in logs and saved stack/profile names. |
| Credential-shaped metadata | Masks PASS/PWD/auth components, passphrases and session cookies alongside the existing key policy. |
| Framework Python MLX discovery | Recognizes Python executable names without case sensitivity. |
| Partial downloads | Lists managed incomplete models as not ready, permits retry/removal after download cancellation, and refreshes inventory after failure/cancellation. |
| Descendants keep pipes open past timeout | Polls output pipes with a bounded shutdown drain; stdin writes also observe cancellation without blocking forever. |
| Cleanup hangs/cancellation | Adds a 30-second delete timeout and Activity cancellation. A cancelled delete stops the queue and reports an uncertain outcome. |
| Dockerfile picker | Accepts extensionless files. |
| Errors hidden behind DNS/kernel/Kubernetes sheets | Displays errors inside sheets and blocks overlapping submissions. |
| One-per-line inputs | Uses vertical fields for repeating flags and build tags. |
| CLI changes during limits apply | Keeps the in-flight review/result intact; Settings disallows path changes while replacement is active. |
| Silent successful resource actions | Supplies an explicit success message when the CLI returns no output. |
| Unreviewed tag releases | Requires release commits to be ancestors of main before running the packaging/publish path. Main branch review protection remains a repository setting. |
| Movable action tags | Pins every workflow action to a verified upstream commit SHA. |
| Release build cache | Removes restored build outputs from the release workflow. |
| Empty live test selection | Requires at least one executed test in each filtered Swift Testing report. |
| Live MLX chat hang | Finishes the bridge stream when its producer finishes and bounds the first-token wait. |
| DNS/chat transport test gaps | Exercises DNS shell quoting without elevation, and tests the real HTTP transport against local sockets for SSE, failure, redirect, truncation and cancellation. |
| Unbounded/flaky test synchronization | Bounds reader polling and replaces catalog, inventory, cleanup and shutdown ordering sleeps with observable synchronization. |
| Corrupt saved plugin libraries | Preserves the last readable in-memory data, blocks writes to unreadable persisted collections and displays the load error. |
| Unsafe executable lookup | Rejects relative overrides, relative PATH components and directory candidates. |
| Short build argument over-redaction | Masks short non-credential values as whole assignments, preserving unrelated digits/text in logs. |
| Refresh/cancellation status | Only completed reads satisfy refresh generations; cancelled command results throw cancellation; the visible Updated clock advances independently of unchanged inventory snapshots. |
| Download cancellation status | Checks cancellation when a stream ends normally, so cancellation is shown in download output. |
| Dead terminal reuse | An exited retained session starts a fresh PTY when remounted. |
| MLX startup with no deadline | Stops a server that stays in starting state beyond the startup deadline and reports startup timeout. |
| Unified Logs navigation | Preserves the in-memory buffer and source selections when returning to the same runtime. |
| Duplicate Cmd-N binding | Uses Shift-Cmd-N for resource creation. |
| Tilde path placeholders | Expands tilde in local path flags before executing the CLI. |
| Icon accessibility | Adds labels to resource refresh/action, image action, model action and stack member controls. |
| Stack log work during rendering | Caches the rendered log projection and updates it when entries or the search change. |
| Documentation mismatches | Aligns the navigation budget with 200 ms, describes the separate CI/release checks, uses release configuration in Quick Start, and documents privileged DNS shell use. |

## Initial local verification

- Release Swift suite: 382 cases, 377 passed, five opt-in live cases skipped, zero failures. This includes escaped pipe holders, an owned terminal ignoring SIGTERM, MLX startup timeout, cancelled cleanup, real loopback HTTP chat, DNS quoting, saved Compose targets, Unicode and corrupt-library protection.
- Python script suite: 22 tests passed.
- Workflow actionlint, shell script ShellCheck, Bash syntax and `git diff --check` passed.
- The final release bundle passed strict code-signature/resource validation and the build script's launch check. Modifying a sealed resource in a temporary copy caused strict verification to reject it.
- Native UI checks confirmed navigation between Builds, Compose and Kubernetes, multiline build-tag editing and retention across navigation, disabled redundant CLI-path buttons, and normal Quit. The checks did not create builds or clusters, edit limits, delete runtime resources, or exercise a quarantined/notarized download.

## Follow-up corrections

The initial verification did not cover all seven follow-up findings. These changes add explicit handling and coverage:

| Finding | Change and verification |
| --- | --- |
| `timeoutTask` race | Timer publication, capture and clearing use the process lock; publication precedes completion notification. A standalone ThreadSanitizer harness reproduced the original race and completed cleanly against the fix. |
| Python `-X` and `-W` | Recognizes attached and separated option values before module/script entry points; parser fixtures cover both forms, malformed flags and `--` option termination. |
| `processFailedToStart` | The native terminal coordinator displays the OS failure, reports an unsuccessful exit callback and invalidates the retained session. A native terminal fixture exercises the callback and retry eligibility. |
| Form-value whitespace | Resource forms use a shared request snapshot; structured identifiers, limits and flags are trimmed. Passwords, paths, quoted command arguments and assignment values retain meaningful whitespace. Both basic and Advanced request builders have coverage. |
| Kubernetes `Set.first` | Remembered clusters use a single optional selection. A native Table fixture verifies that multiple selection is disabled. Editing the action name clears a different selected row. |
| OSC escapes | A bounded state machine strips OSC/CSI/control strings before line assembly, maintaining state per source and pipe across chunks. Fixtures cover hyperlink/title payloads, split terminators, C1 controls, large unterminated payloads and Unicode text. |
| Recovery retention | New sessions durably record `inProgress` before replacement and their final outcome afterward. Settings provides **Review Limits Recovery Files…**, with allocated-size estimates, manual selection and permanent-removal confirmation. Filesystem fixtures exercise reference protection, stale outcomes/files, incomplete inventory, repeated edits and protected interrupted/manual-recovery sessions. |

Recovery cleanup only removes reviewed `updated` or `rolledBack` sessions with no references in a complete inventory of all containers, including stopped containers. It checks actual and stored kernel/initfs/rootfs paths and mount sources, resolving symlinks and accounting for filesystem case sensitivity. Within the app, runtime mutations and limits edits are excluded while removal holds its operation lease. Files and directory identities are checked again before descriptor-relative unlink operations; unexpected files are not recursively removed.

Missing, unknown, interrupted and `recoveryNeeded` outcomes are always kept, even when no container references them. Consequently, sessions created by older versions remain protected. There is no automatic startup cleanup. Reported allocation is an estimate; APFS clone sharing means actual reclaimed space can differ. Tests remove only temporary fixtures; no real recovery session was deleted during verification.

Follow-up verification: 401 release-suite cases (396 passed, five opt-in live cases skipped), zero failures; 22 Python tests passed. Actionlint, ShellCheck and `git diff --check` passed. The ThreadSanitizer harness was configured for 512 fast-process launches across eight workers: the original reported a data race; the corrected runner completed the workload with none reported.

The rebuilt release app passed strict bundle/signature validation and launched successfully. Native UI inspection opened Settings → Limits Recovery Files and verified the size/privacy guidance, manual selection workflow and disabled removal button with no selection. This machine had no listed recovery sessions; protected/removable rows and destructive removal were verified with temporary fixtures rather than user backups. Normal Quit completed after the check.

## Remaining-review follow-up

The release-gate item was excluded from this follow-up at the user's request.

| Finding | Change and evidence |
| --- | --- |
| Timed-out cleanup delete reported as failed | A typed timeout now triggers an inventory post-check. Confirmed disappearance is reported as removed; a present/unreadable target is unverified. The queue stops before another deletion. Tests cover both outcomes and reproduce the previous failure. |
| Whole resource view observes every poll timestamp | `ResourceUpdatedLabel` owns timestamp observation. An observation test confirms unchanged polls invalidate that leaf while the resource view remains uninvalidated, with a query-change positive control. |
| System tabs drop reads behind `guard !busy` | Tab reads start before the status refresh and have their own loading state, cancellation and generation checks, separate from administrative actions. A blocked older read cannot prevent a newer tab read or publish into it. Empty service logs have an explicit empty-result message. |
| Tokenizer line continuation | Backslash-newline no longer activates an empty argument. Fixtures cover an otherwise empty command, whitespace, between arguments, inside words and explicitly empty quoted arguments; the previous implementation fails these fixtures. |
| Quit waits indefinitely for limits recovery | Shows a progress window with Keep App Open. After 30 seconds, declines termination and explains that recovery continues in the open app. Waiter tests cover completion, timeout and user cancellation; the app does not forcibly interrupt disk recovery. |
| Normally exited leader leaves output pipes open | Leader exit starts a one-second drain deadline even without a command timeout. Pipes still open afterward are closed and output is marked truncated. An escaped-descendant fixture reproduces the previous hang/late timeout and now finishes with the leader's normal result and incomplete-output flag. |
| Output pipes wake every 50 ms | Nonblocking pipe reads use Dispatch readiness sources. Only leader exit/cancellation schedules a single delayed close. The stdin writer's existing backpressure polling is separate. Existing output, Unicode, redaction, cancellation, overflow and quiet-process tests pass. |
| Corrupt plugin library has no in-app recovery | Compose and Kubernetes offer Library Recovery: retry, export exact saved data, import repaired JSON, or reset with confirmation. Import/reset require a private, synced backup and recheck the exact saved value before replacing only the selected collection. Tests cover wrong-type data, failed backups, stale reviews, imports and writes after recovery. |
| Empty initial Logs source selection sticks | Waits for the first nonempty successful inventory, including after an empty/failed initial read. An explicit user source choice, including Deselect All, is preserved. Fixtures cover delayed inventory and explicit empty selection. A native Logs view fixture also reproduces recovery with unchanged retained IDs; observing the full snapshot catches the load-state transition. |

Fresh verification: 411 release-suite entries, 406 passed and five opt-in live entries skipped, with zero failures. The focused pre-fix runs reproduced the timeout report, tokenizer, normally exited leader, and native Logs load-state recovery failures. The ThreadSanitizer fast-process workload completed cleanly against the new readiness readers. Actionlint, ShellCheck and `git diff --check` passed. No real cleanup deletion, limits recreation, library reset or recovery-file removal was performed.

The final source was rebuilt and packaged in release configuration, passed strict signature/resource validation, and launched successfully. Native checks on that bundle loaded Disk Usage, Properties, DNS Domains and System Logs with each tab showing its own result; normal Quit completed. Active-recovery Quit behavior and library replacement were exercised with fixtures, without changing user containers or libraries.

## Final merge-review corrections

The five findings from the full working-diff review have dedicated regression coverage:

| Finding | Correction and regression coverage |
| --- | --- |
| Completion helpers escape Quit | Accepted termination permanently closes process admission under the descriptor/spawn lock. AppStore closes command, read, limits and cleanup admission, cancels tracked workers and joins command tasks, Build/Kubernetes owners and build completion callbacks. Tests check rejected late reads/streams, owner completion, and an isolated real-process registry closing admission while existing process cleanup remains possible. The limits wait still precedes this irreversible shutdown phase. |
| Older DNS refresh clears a newer busy guard | All System administrative actions use one operation owner through their complete action and refresh. Tests hold the refresh pending, reject another submission, and check release/error behavior on both success and failure. |
| Advanced paths are trimmed | Each flag declares structured, literal, host-path or guest-path treatment. Host paths preserve whitespace and expand tilde; guest paths and composite/literal values preserve their bytes. Tests cover supported kernel, workdir, cidfile, masked/read-only, archive and runtime-root flags, host/guest tilde behavior and continued CPU-value trimming. |
| Stacks observes poll timestamps in its parent | Stacks reuses ResourceUpdatedLabel. An observation test keeps the parent quiet on identical polls, confirms the label updates, and confirms real inventory changes still invalidate Stacks. |
| Cached logs miss eviction-only changes | The log revision combines a session identity with a visible-entry mutation counter. Appends and evictions advance it; replacing a buffer changes its identity. Tests cover partial-line eviction at production size limits, equal-count session replacement, value copies, and no extra invalidation for partial text that leaves visible entries unchanged. |

The pre-fix test run reproduced path corruption, whole-Stacks timestamp observation, incomplete shutdown ownership and stale log revisions. The earlier controlled DNS probe reproduced the stale busy write; the maintained action-owner tests now exercise its two-await lifetime boundary. The final full-diff review and packaged UI verification are complete. The release-gate bypass remains excluded.

Final verification: 420 release-suite entries, 415 passed and five opt-in live entries skipped, with no failures. All nine new regression functions passed, including 12 path cases and both administrative refresh outcomes. The pre-fix tests failed for the reviewed shutdown, path, Stacks observation and log-cache defects. The process-runner ThreadSanitizer workload completed cleanly; all 22 Python tests, Actionlint, ShellCheck and `git diff --check` passed.

Two fresh independent reviews examined the entire 83-file working diff against `8c3f19d`, on requirements/correctness and standards/performance axes. Both reported no additional actionable findings within the included scope. The implementation hashes stayed unchanged during review and packaging.

The final release app passed strict signature/resource validation and launch checks. Native inspection confirmed DNS validation errors remain inside the action sheet, subsequent System reads work, the Stacks timestamp is displayed, and normal Quit completes. The validation check used an invalid domain and did not request elevation. Actual DNS changes, kernel installs, container mutations and recovery deletions were not performed; their destructive paths remain fixture-tested or opt-in. No merge was performed.

Pre-PR verification exposed test-only scheduling assumptions and a loopback HTTP fixture race. Inventory synchronization now has a ten-second bound to accommodate parallel native-view work. Quit checks its timeout, ready and cancellation outcomes within a test time limit; the inherited-pipe test requires normal completion without hitting its command timeout, instead of measuring unrelated scheduler delays. The HTTP fixture consumes the complete size-bounded, length-delimited request before replying, with a socket read timeout, so closing it cannot discard the response because request data remains unread. These fixture changes were reviewed separately; the packaged application implementation is unchanged.

The focused HTTP suite and final complete release rerun passed: 420 entries, 415 passed, five opt-in live entries skipped, no failures or errors. The 22 Python tests, Actionlint, ShellCheck and whitespace checks also passed before publishing the branch.
