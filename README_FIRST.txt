PATTERN LABORATORY SUITE VERSION 8.2
====================================
Native Windows x64 research software for Cayley permutations and restricted
 growth functions (RGFs).

The suite contains two separate graphical applications backed by one shared
native C++ engine:

    CayleyPatternLaboratory.exe     Cayley permutations / surjective words
    RGFPatternLaboratory.exe        restricted growth functions / set partitions
    PatternEngine.exe               shared command-line computation engine

No WSL, Ubuntu, compiler installation, or administrator access is required.

QUICK START
-----------
1. Extract the complete ZIP into an ordinary local Windows folder, for example:

       C:\Pattern_Laboratory_v8_2

   Do not run individual files from inside the ZIP archive.

2. Double-click the application you want:

       CayleyPatternLaboratory.exe
       RGFPatternLaboratory.exe

3. Click Run self-test once. The final line in the Log tab must be:

       Self-test passed.

4. Enter one avoidance class per line, choose First n, Last n, Threads, and any
   statistic options, then click Run enumeration.

5. Results appear in the Totals and refined-result tabs. Nothing is saved
   permanently unless you explicitly choose an Export command.

Windows may show a SmartScreen warning because this research build is not
digitally signed. Complete source code is included for inspection.

OEIS FINITE-SEQUENCE CHECK
------------------------
After enumeration, the Totals by n table ends with an OEIS* footer row. Each
avoidance-class cell is checked independently against the online OEIS search.
The interface distinguishes:

- an indexed match, where the OEIS offset aligns with the displayed n;
- a value-list match, where the same finite list occurs with another offset;
- no match among the returned search results; and
- an unavailable lookup, normally caused by no Internet connection.

At least six terms are required. Up to 10 consecutive displayed terms are sent
to the OEIS, preferring the latest terms when the table is longer. The lookup is
performed in the background and does not block the enumerator. Hover over a
footer cell for details, double-click to open the OEIS, or right-click for more
commands. The footer is never included in a CSV export.

A finite-sequence match is not a proof that the enumerated class has the same
infinite counting sequence as an OEIS entry; subsequent terms may diverge.

Version 8.2 fixes the Windows PowerShell single-result case: when exactly one
OEIS entry matches, the footer now reports that A-number instead of displaying
an unavailable-lookup error concerning a missing Count property.

THE TWO OBJECT FAMILIES
-----------------------
Cayley mode generates every surjective word w in [k]^n, separately for each
maximum k. Counts refined by k therefore count ordered set partitions.

RGF mode generates words satisfying

       w_1 = 1,
       w_i <= 1 + max(w_1,...,w_{i-1}).

Every RGF is the canonical word encoding of a set partition. Its maximum k is
its number of blocks, so the refined RGF table is indexed by block count. In the
unrestricted case the total row is the Bell number B_n and the exact-k row is
the Stirling number S(n,k).

The applications deliberately have separate interfaces because "maximum k" and
"number of blocks k" play different mathematical roles, but all pattern parsing,
containment tests, statistics, browsing, diagrams, and exports are shared.

PATTERN CONTAINMENT
-------------------
For either object family, a selected subword is an occurrence of p when it has
exactly the same strict inequalities, reverse inequalities, and equalities as p.
Equivalently, order-standardisation preserving equal entries gives p.

A bare pattern is classical:

       avoid_121 = 121
       avoid_312 = classical:312

A consecutive pattern requires every selected position to be adjacent:

       avoid_consecutive_121 = consecutive:121

A vincular pattern records required adjacency bonds after a vertical bar. Bond
j requires the j-th and (j+1)-st entries of the occurrence to be adjacent:

       avoid_bonded_1232 = vincular:1232|2
       avoid_two_bonds   = vincular:12321|1,3

Mixed bases are permitted:

       mixed = 121 + consecutive:11 + vincular:1232|2

The aliases c:, con:, and v: are accepted. Patterns must be packed/Cayley words:
their distinct ranks are 1,2,...,r. For values 10 and above, use spaces or
commas. In RGF mode the basis pattern itself need not satisfy the RGF growth
rule; patterns such as 312 are accepted.

RGF ENUMERATION
---------------
An RGF prefix with current maximum m has precisely m+1 possible next letters:
1,...,m,m+1. The first letter is forced to be 1. For a fixed target block count
k, the engine never permits a letter above k and prunes a prefix if too few
positions remain to introduce all missing block labels.

Avoidance is prefix-hereditary. After appending one entry, the prefix engine
checks only for forbidden occurrences whose final selected position is the new
entry. If such an occurrence appears, no extension can repair the prefix, so the
whole subtree is discarded. The surviving search tree is divided into many RGF
prefix subtrees and dynamically distributed among native worker threads.

See RGF_GUIDE.txt and NATIVE_ARCHITECTURE.txt for more detail.

STATISTICS
----------
Both applications support 29 scalar, set-valued, and evaluation statistics,
including ascents, descents, major index, inversions, peaks, exact descent sets,
fixed points, runs, and evaluation.

Tick:

       Collect selected statistic distributions during enumeration

and choose Select statistics. The engine accumulates each distribution while
it streams through the avoiders. The complete word list does not need to be
stored. After the run, use the Statistics tab to select the class, statistic,
length, and either all maxima/block counts or one exact k.

In the RGF application:
- maximum is displayed as number of blocks;
- evaluation is the block-size vector;
- singleton and repeated letters are singleton and nonsingleton blocks.

Version 8 calculates separate one-statistic distributions, not automatic joint
distributions. See STATISTICS_REFERENCE.txt.

VIEWING OBJECTS AND DIAGRAMS
----------------------------
Right-click a row in either result table, choose a class, and select the list or
diagram command. The browser requests 100 objects at a time by default and can
show any supported statistic beside each word, even when that statistic was not
collected as a class-wide distribution.

Words with entries at most 9 use compact notation, such as 121354. If an entry
is 10 or larger, entries are separated by spaces.

For w=w_1...w_n, both viewers use an n by n grid with one dot at each coordinate
(i,w_i). Repeated entries appear on the same horizontal row. Use Previous/Next,
the left/right arrow keys, or the jump box.

PATTERN-CONTAINMENT TOOLS
-------------------------
The left side of the Pattern containment tab inspects one entered word against a
classical, consecutive, or vincular pattern. It reports the number of
occurrences and lists their position sets and selected values.

The right side computes the complete occurrence distribution of a query pattern
inside one current avoidance class. The row indexed by r counts objects with
exactly r occurrences; the row r=0 is therefore the class obtained by adding the
query pattern to the basis.

STORAGE MODES
-------------
Count only:
- retains enumeration tables only;
- requested pages are regenerated on demand.

Selected statistic distributions:
- retains only the requested distributions;
- normally much smaller than storing all objects.

Temporarily store every avoider:
- creates temporary catalogues for unrestricted browsing and later checks;
- may consume substantial time and disk space;
- catalogues are removed when a new run starts or the GUI closes normally.

PERFORMANCE AND LIMITS
----------------------
- On a 16-thread machine, Threads=16 is appropriate. Threads=0 uses all logical
  processors reported by Windows.
- Counts are exact and use unsigned 128-bit arithmetic.
- The compiled length limit is n <= 24; at most 64 classes can share one run.
- Enumeration remains exponential in the worst case.
- Exact set-valued distributions, evaluations, complete catalogues, and short-
  pattern occurrence distributions can become large.
- The Cayley and RGF generators use different search trees but share the same
  generalized-pattern detector and statistic code.

CANCELLATION
------------
Click Cancel. The GUI terminates the native engine process tree. Fully completed
rows already flushed to temporary files may survive; the current unfinished row
need not be complete.

FALLBACKS AND SHORTCUTS
-----------------------
If a native GUI launcher is blocked by local security policy, use the matching
VBS launcher. The BAT launchers leave a diagnostic console visible.

Double-click Create_Desktop_Shortcuts.vbs to create shortcuts for both apps.
Run_Engine_Self_Test.bat validates the common engine directly.

FILES
-----
PatternEngine.exe                    shared native C++ engine
PatternEngine.cpp                    complete engine source
CayleyPatternLaboratory.exe          native Cayley GUI launcher
CayleyPatternLaboratory.ps1          Cayley Windows Forms interface
RGFPatternLaboratory.exe             native RGF GUI launcher
RGFPatternLaboratory.ps1             RGF Windows Forms interface
RGF_GUIDE.txt                        RGF definitions and search details
ENGINE_COMMAND_LINE.txt              direct engine use
NATIVE_ARCHITECTURE.txt              implementation overview
STATISTICS_REFERENCE.txt             statistic definitions
VALIDATION.txt                       release validation record
