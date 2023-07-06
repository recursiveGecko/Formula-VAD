# Formula-VAD

Work in progress.

Project dedicated to audio analysis of F1 onboard streams for the purposes of radio transcription (& more coming soon).


# Current VAD results

As of `2023-06-10`.

```
=> Definitions

P   (Positives):                            Total duration of real speech segments (from reference labels)
TP  (True positives):                       Duration of correctly detected speech segments
FP  (False positives):                      Duration of incorrectly detected speech segments
FN  (False negatives):                      Duration of missed speech segments
TPR (True positive rate, sensitivity):      Probability that VAD detects a real speech segment. = TP / P 
PPV (Precision, Positive predictive value): Probability that detected speech segment is true.   = TP / (TP + FP) 
FNR (False negative rate, miss rate):       Probability that VAD misses a speech segment.       = FN / P 
FDR (False discovery rate):                 Probability that detected speech segment is false.  = FP / (TP + FP) 

=> Performance Report

|                           Name |    P |   TP |   FP |   FN |    TPR |    PPV |  FNR (!) |  FDR (!) |
| ------------------------------ | ---- | ---- | ---- | ---- | ------ | ------ | -------- | -------- |
|        2023 Monaco FP1 - Perez | 1137 | 1135 |    5 |    2 |  99.8% |  99.6% |     0.2% |     0.4% |
|     2023 Miami Race - Sargeant | 1092 | 1075 |    6 |   17 |  98.4% |  99.4% |     1.6% |     0.6% |
|        2023 Miami Race - Gasly | 1447 | 1362 |   23 |   86 |  94.1% |  98.3% |     5.9% |     1.7% |
|        2023 Miami Race - Perez | 1025 |  996 |    5 |   29 |  97.2% |  99.5% |     2.8% |     0.5% |
|      2023 Miami Race - Leclerc | 1222 | 1222 |    0 |    0 | 100.0% | 100.0% |     0.0% |     0.0% |
|     2023 Miami Race - De Vries |  952 |  940 |    0 |   12 |  98.7% | 100.0% |     1.3% |     0.0% |
|         2023 Miami Race - Zhou | 1082 | 1070 |   11 |   12 |  98.9% |  99.0% |     1.1% |     1.0% |
|    2023 Miami Race - Magnussen | 1028 | 1020 |    6 |    7 |  99.3% |  99.5% |     0.7% |     0.5% |
|      2023 Miami Race - Russell | 1435 | 1398 |    8 |   37 |  97.4% |  99.4% |     2.6% |     0.6% |
|       2023 Miami Race - Norris |  513 |  512 |    0 |    1 |  99.8% | 100.0% |     0.2% |     0.0% |
|       2023 Miami Race - Stroll | 1114 | 1108 |    0 |    6 |  99.5% | 100.0% |     0.5% |     0.0% |
|      2023 Miami Race - Tsunoda |  671 |  664 |    0 |    6 |  99.1% | 100.0% |     0.9% |     0.0% |
|   2023 Miami Race - Verstappen | 1049 | 1039 |    0 |   10 |  99.0% | 100.0% |     1.0% |     0.0% |
|        2023 Miami Race - Sainz | 1447 | 1436 |    8 |   11 |  99.3% |  99.4% |     0.7% |     0.6% |
|        2023 Miami Race - Albon |  561 |  547 |    0 |   14 |  97.5% | 100.0% |     2.5% |     0.0% |
|   2023 Miami Race - Hulkenberg |  617 |  617 |   18 |    0 | 100.0% |  97.2% |     0.0% |     2.8% |
|         2023 Miami Race - Ocon |  597 |  594 |   14 |    3 |  99.5% |  97.7% |     0.5% |     2.3% |
|     2023 Miami Race - Hamilton | 1261 | 1233 |   10 |   28 |  97.8% |  99.2% |     2.2% |     0.8% |
|       2023 Miami Race - Alonso | 1172 | 1154 |    0 |   18 |  98.4% | 100.0% |     1.6% |     0.0% |
|       2023 Miami Race - Bottas |  575 |  573 |    0 |    2 |  99.6% | 100.0% |     0.4% |     0.0% |
|      2023 Miami Race - Piastri |  822 |  782 |    0 |   40 |  95.1% | 100.0% |     4.9% |     0.0% |

=> Aggregate stats 

Total speech duration  (P): 20822.3 sec
True positives        (TP): 20480.1 sec
False positives       (FP):   113.3 sec
False negatives       (FN):   342.2 sec    Min.    Avg.    Max. 
True positive rate   (TPR):    98.4%  |   94.1% / 98.5% /100.0% 
Precision            (PPV):    99.4%  |   97.2% / 99.4% /100.0% 
False negative rate  (FNR):     1.6%  |    0.0% /  1.5% /  5.9% 
False discovery rate (FDR):     0.6%  |    0.0% /  0.6% /  2.8% 
F-Score (β =  0.70)       :    99.1% 
Fowlkes-Mallows index     :    98.9% 
```

# Cloning

This project uses Git submodules.

```bash
git clone --recursive https://github.com/recursiveGecko/formula-vad
```

# Dependencies

* Zig: `0.11.0 master`. Requires ~`0.11.0-dev.3937+78eb3c561`.

* libsndfile:

  * On Debian/Ubuntu: `apt install libsndfile1 libsndfile1-dev`


# Simulator

A JSON file containing the run plan needs to be created, an example can be found in `tmp/plan.example.json`.

Any relative paths inside the JSON file are relative to the JSON file itself, not the current working directory.

Suggested optimization modes are either `ReleaseSafe` or `ReleaseFast`.

To run the simulator:

```bash
zig build -Doptimize=ReleaseSafe && ./zig-out/bin/simulator -i tmp/plan.json
```
