[README.md](https://github.com/user-attachments/files/33837349/README.md)
# Pattern Laboratory

Pattern Laboratory is a Windows application for enumerating pattern-avoiding **Cayley permutations** and **restricted growth functions (RGFs)**. It provides counting tables, statistic distributions, object lists, diagrams, and pattern-containment tools.

The suite includes two graphical applications:

| Application | Objects |
| --- | --- |
| `CayleyPatternLaboratory.exe` | Cayley permutations: words whose distinct entries are exactly `1, 2, ..., k`. |
| `RGFPatternLaboratory.exe` | Restricted growth functions: the canonical word encodings of set partitions. |

Both applications use the shared native C++ engine, `PatternEngine.exe`.

## Requirements

- **64-bit Windows 10 or Windows 11 on an Intel/AMD processor.**
- Windows PowerShell 5.1, normally included with Windows.
- Internet access only for the optional OEIS lookup; enumeration works offline.

No Python, WSL, Ubuntu, or compiler installation is required. Administrator access is not normally required. The supplied executables do not run directly on macOS or Linux.

## Download and run

1. Open the [Releases page](https://github.com/mattslatteryholmes/patternlab/releases) and download the Windows ZIP attached to the release. For version 8.2, look for `PatternLaboratory-v8.2-Windows-x64.zip`.
   If a packaged release is not available, use **Code → Download ZIP** on the [repository page](https://github.com/mattslatteryholmes/patternlab). The repository also includes the compiled executables.
2. **Extract the entire ZIP** into a local folder, for example `Documents\PatternLaboratory`. Do not launch files from inside the ZIP.
3. Open the extracted folder and double-click `CayleyPatternLaboratory.exe` or `RGFPatternLaboratory.exe`.
4. Click **Run self-test**. The final line in the **Log** tab should be `Self-test passed.`

Keep the extracted files together. Each application needs its matching `.ps1` interface script and the shared `PatternEngine.exe` in the same folder.

This research build is not digitally signed, so Windows may display a security warning. Only run a copy you trust. If an institutional computer blocks the application, contact your IT team.

## A first enumeration

1. Open **Cayley Pattern Laboratory**.
2. Enter this avoidance class:

   ```text
   avoid_121 = 121
   ```

3. Set **First n** to `1`, **Last n** to `6`, and **Threads** to `0`.
4. Click **Run enumeration**.
5. View the **Totals** and refined-result tabs.
6. Use an **Export** command to save results you want to keep.

`n` is the word length. Cayley counts are refined by the maximum entry `k`; RGF counts are refined by the number of blocks `k`. Setting **Threads** to `0` uses all logical processors reported by Windows. Choose a smaller positive number to use fewer processors.

**Results are not saved permanently unless you export them.**

## Entering avoidance classes

Enter one class per line. The text before `=` is a label; patterns after `=` form the forbidden basis. Use `+` to require avoidance of every pattern in that basis.

```text
avoid_121 = 121
avoid_132_4231 = 132 + 4231
avoid_consecutive_121 = consecutive:121
avoid_bonded_1232 = vincular:1232|2
mixed = 121 + consecutive:11 + vincular:1232|2
```

- **Classical patterns:** bare patterns, such as `121`, allow gaps between selected positions. The prefix `classical:` is also accepted.
- **Consecutive patterns:** `consecutive:121` requires all selected positions to be adjacent.
- **Vincular patterns:** `vincular:1232|2` requires the second and third selected positions to be adjacent. Multiple required bonds can be written as `vincular:12321|1,3`.

Containment preserves both inequalities and equalities. For example, an occurrence of `121` has equal first and third entries, with a larger middle entry.

Patterns must use consecutive ranks starting at `1`. For entries of `10` or above, separate values with spaces or commas. In the RGF application, forbidden patterns need not themselves satisfy the RGF growth rule.

## Features

- Classical, consecutive, and vincular pattern avoidance, including mixed bases.
- Multiple avoidance classes in one run.
- Counts by length and by maximum entry or block count.
- 29 supported statistics, including descents, major index, inversions, peaks, descent sets, and evaluation.
- Object browsing and grid diagrams.
- Pattern-occurrence inspection and occurrence distributions.
- CSV exports and optional OEIS sequence lookups.

To collect statistic distributions, tick **Collect selected statistic distributions during enumeration**, choose **Select statistics**, and select the statistics before running. View the results in the **Statistics** tab. Version 8.2 collects separate distributions for individual statistics, rather than automatic joint distributions.

Right-click a result row to access object lists and diagrams. Objects can be regenerated in pages when needed; storing every avoider is optional.

## OEIS lookup

After an enumeration with at least six displayed terms, the application can check the finite sequence against the OEIS. The lookup runs in the background. Hover over an **OEIS*** footer cell for details or double-click it to open the OEIS.

A matching finite sequence is evidence for further investigation, not a proof that the infinite counting sequences agree. If the lookup is unavailable, enumeration results remain usable.

Version 8.2 fixes an OEIS lookup error that could occur in Windows PowerShell when exactly one matching entry was returned.

## Performance and troubleshooting

- Start with small lengths and increase them gradually. Running time depends strongly on the forbidden patterns.
- The compiled limits are `n <= 24` and at most 64 classes per run. These are software limits, not a guarantee that every permitted calculation is practical.
- Complete avoider catalogues and some statistic distributions can consume substantial memory or disk space. Start with counting only when exploring a large class.
- Click **Cancel** to stop a run. An unfinished row should not be treated as a completed count.
- If an interface script or engine is reported missing, extract the full ZIP again and keep all files in the same folder.
- If the application does not open, its matching `Launch_Cayley_Pattern_Laboratory.bat` or `Launch_RGF_Pattern_Laboratory.bat` launcher can expose diagnostic messages.

## Documentation and source

- [Detailed usage instructions](README_FIRST.txt)
- [RGF guide](RGF_GUIDE.txt)
- [OEIS lookup guide](OEIS_LOOKUP_GUIDE.txt)
- [Version 8.2 validation notes](VALIDATION_v8_2.txt)
- [Cayley example classes](cayley_classes_examples.txt)
- [RGF example classes](rgf_classes_examples.txt)

The C++ engine and launcher source files, together with the PowerShell interfaces, are included in the repository.

To report a problem, [open an issue](https://github.com/mattslatteryholmes/patternlab/issues) with the application and version used, your Windows version, the exact class input, the length range, relevant options, and any error or log output.
