# The Art of Verification: Verification Basics demos

The code for every lesson of the free [Verification Basics course](https://theartofverification.com/verification-basics-course/) on [theartofverification.com](https://theartofverification.com/).

Each lesson takes one small design, plants bugs in it, and shows a bench finding them. Every file here is the exact file from the lesson, and every expected output comes from a real run on Synopsys VCS X-2025.06-SP1 on EDA Playground. The run date is in each file's header.

## Lessons

| # | Lesson | Folder | Top module |
|---|---|---|---|
| 1 | [How to Think Like a Verification Engineer: From Spec to Scenarios](https://theartofverification.com/how-to-think-like-a-verification-engineer/) | [`01-think-like-a-verifier`](01-think-like-a-verifier/) | `alu_tb` |
| 2 | [The Thought Process Behind Great Verification: 5 Habits That Find Real Bugs](https://theartofverification.com/verification-thinking-habits/) | [`02-thinking-habits`](02-thinking-habits/) | `tav_top` |
| 3 | [How to Build a Strong Verification Plan: From Spec to Sign-Off](https://theartofverification.com/verification-plan/) | [`03-verification-plan`](03-verification-plan/) | `tav_top` |
| 4 | [The Stages of IP Verification: From Plan to Sign-Off (With a UVM Example)](https://theartofverification.com/ip-verification-stages/) | [`04-ip-verification-stages`](04-ip-verification-stages/) | `tav_top` |
| 5 | [Stress Verification in UVM: Finding the Bugs Normal Random Testing Misses](https://theartofverification.com/stress-verification/) | [`05-stress-verification`](05-stress-verification/) | `tav_top` |
| 6 | [Debugging in Verification: The Art and Science of Finding the Real Bug](https://theartofverification.com/debugging-in-verification/) | [`06-debugging`](06-debugging/) | `tav_top` |
| 7 | [How to Solve a Complex Verification Issue: Reproduce, Shrink and Isolate a Rare Bug](https://theartofverification.com/intermittent-bug-debugging/) | [`07-rare-bug-debugging`](07-rare-bug-debugging/) | `tav_top` |
| 8 | [Formal vs Functional Verification: What Each One Proves, With a Real Example](https://theartofverification.com/formal-vs-functional-verification/) | [`08-formal-vs-functional`](08-formal-vs-functional/) | `tav_top` |

## How to run any demo

1. Open [EDA Playground](https://www.edaplayground.com/) and sign in (free).
2. Paste the lesson's `.sv` file into testbench.sv. Leave design.sv empty.
3. Pick Synopsys VCS. For lessons 2 to 8, also pick UVM 1.2.
4. Set the top module from the table above and run.
5. Add `+BUG=1`, `+BUG=2` or `+BUG=3` to Run Options to switch one planted bug on, and watch the bench catch it.

Lesson 8 also has a formal harness that runs on free, open-source Yosys. Its README has the commands.

## Naming

From lesson 2 on, every name the bench defines starts with `tav_`, so you can tell the demo code apart from UVM library code at a glance.

## Questions or a bug in a demo?

Open an issue here, or comment on the lesson.

## License

MIT. See `LICENSE`. Use the demos freely; please keep the header that credits The Art of Verification.
