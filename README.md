# Formula-VAD

Work in progress.

Project dedicated to audio analysis of F1 onboard streams for the purposes of radio transcription (& more coming soon).


# Current VAD results

As of `2024-03-10`.

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
|     2023 Miami Race - Sargeant | 1098 | 1081 |    0 |   18 |  98.4% | 100.0% |     1.6% |     0.0% |
|        2023 Miami Race - Gasly | 1463 | 1379 |   22 |   83 |  94.3% |  98.4% |     5.7% |     1.6% |
|        2023 Miami Race - Perez | 1038 | 1018 |    5 |   20 |  98.1% |  99.5% |     1.9% |     0.5% |
|      2023 Miami Race - Leclerc | 1210 | 1210 |    0 |    0 | 100.0% | 100.0% |     0.0% |     0.0% |
|     2023 Miami Race - De Vries |  959 |  950 |    0 |    9 |  99.1% | 100.0% |     0.9% |     0.0% |
|         2023 Miami Race - Zhou | 1081 | 1074 |    5 |    7 |  99.4% |  99.5% |     0.6% |     0.5% |
|    2023 Miami Race - Magnussen | 1027 | 1025 |    8 |    1 |  99.9% |  99.2% |     0.1% |     0.8% |
|      2023 Miami Race - Russell | 1446 | 1431 |    8 |   15 |  99.0% |  99.4% |     1.0% |     0.6% |
|       2023 Miami Race - Norris |  508 |  507 |    0 |    1 |  99.8% | 100.0% |     0.2% |     0.0% |
|       2023 Miami Race - Stroll | 1113 | 1106 |    0 |    7 |  99.3% | 100.0% |     0.7% |     0.0% |
|      2023 Miami Race - Tsunoda |  669 |  665 |    0 |    4 |  99.4% | 100.0% |     0.6% |     0.0% |
|   2023 Miami Race - Verstappen | 1047 | 1041 |    0 |    5 |  99.5% | 100.0% |     0.5% |     0.0% |
|        2023 Miami Race - Sainz | 1428 | 1401 |    8 |   27 |  98.1% |  99.4% |     1.9% |     0.6% |
|        2023 Miami Race - Albon |  570 |  560 |   12 |   10 |  98.2% |  97.9% |     1.8% |     2.1% |
|   2023 Miami Race - Hulkenberg |  613 |  613 |   17 |    0 | 100.0% |  97.3% |     0.0% |     2.7% |
|         2023 Miami Race - Ocon |  591 |  589 |   12 |    2 |  99.7% |  98.0% |     0.3% |     2.0% |
|     2023 Miami Race - Hamilton | 1256 | 1217 |    9 |   39 |  96.9% |  99.3% |     3.1% |     0.7% |
|       2023 Miami Race - Alonso | 1184 | 1174 |    0 |   10 |  99.2% | 100.0% |     0.8% |     0.0% |
|       2023 Miami Race - Bottas |  585 |  583 |    0 |    2 |  99.7% | 100.0% |     0.3% |     0.0% |
|      2023 Miami Race - Piastri |  793 |  733 |    0 |   60 |  92.5% | 100.0% |     7.5% |     0.0% |

=> Aggregate stats 

Total speech duration  (P): 19677.4 sec
True positives        (TP): 19357.8 sec
False positives       (FP):   107.6 sec
False negatives       (FN):   319.6 sec    Min.    Avg.    Max. 
True positive rate   (TPR):    98.4%  |   92.5% / 98.5% /100.0% 
Precision            (PPV):    99.4%  |   97.3% / 99.4% /100.0% 
False negative rate  (FNR):     1.6%  |    0.0% /  1.5% /  7.5% 
False discovery rate (FDR):     0.6%  |    0.0% /  0.6% /  2.7% 
F-Score (β =  0.70)       :    99.1% 
Fowlkes-Mallows index     :    98.9% 
```

# Dependencies

* Zig: `0.13.0`

* libsndfile:

  * On Debian/Ubuntu: `apt install libsndfile1 libsndfile1-dev`


# Simulator

A JSON file containing the run plan needs to be created, an example can be found in `tmp/plan.example.json`.

Any relative paths inside the JSON file are relative to the JSON file itself, not the current working directory.

Suggested optimization mode: `ReleaseSafe`

To run the simulator:

```bash
zig build -Doptimize=ReleaseSafe && time ./zig-out/bin/simulator -i tmp/plan.json
```
