# Formula-VAD

Work in progress.

Project dedicated to audio analysis of F1 onboard streams for the purposes of radio transcription (& more coming soon).


# Current VAD results

As of `2023-06-10` with experimental Silero VAD.

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
|        2023 Monaco FP1 - Perez | 1158 | 1125 | 1164 |   33 |  97.1% |  49.1% |     2.9% |    50.9% |
|     2023 Miami Race - Sargeant | 1091 | 1016 |  666 |   75 |  93.2% |  60.4% |     6.8% |    39.6% |
|        2023 Miami Race - Gasly | 1935 | 1889 | 3110 |   46 |  97.6% |  37.8% |     2.4% |    62.2% |
|        2023 Miami Race - Perez | 1378 | 1338 | 3485 |   40 |  97.1% |  27.7% |     2.9% |    72.3% |
|      2023 Miami Race - Leclerc |  917 |  778 |    0 |  140 |  84.8% | 100.0% |    15.2% |     0.0% |
|     2023 Miami Race - De Vries |  996 |  964 | 2377 |   32 |  96.8% |  28.8% |     3.2% |    71.2% |
|         2023 Miami Race - Zhou |  768 |  610 |  227 |  158 |  79.4% |  72.9% |    20.6% |    27.1% |
|    2023 Miami Race - Magnussen |  984 |  941 |   24 |   43 |  95.6% |  97.5% |     4.4% |     2.5% |
|      2023 Miami Race - Russell | 1767 | 1643 | 2925 |  124 |  93.0% |  36.0% |     7.0% |    64.0% |
|       2023 Miami Race - Norris |  461 |  422 | 1404 |   39 |  91.6% |  23.1% |     8.4% |    76.9% |
|       2023 Miami Race - Stroll | 1038 |  993 |    0 |   45 |  95.6% | 100.0% |     4.4% |     0.0% |
|      2023 Miami Race - Tsunoda |  852 |  839 | 3895 |   14 |  98.4% |  17.7% |     1.6% |    82.3% |
|   2023 Miami Race - Verstappen | 1287 | 1270 | 2737 |   18 |  98.6% |  31.7% |     1.4% |    68.3% |
|        2023 Miami Race - Sainz | 1092 |  901 |    0 |  191 |  82.5% | 100.0% |    17.5% |     0.0% |
|        2023 Miami Race - Albon |  566 |  506 | 1826 |   61 |  89.3% |  21.7% |    10.7% |    78.3% |
|   2023 Miami Race - Hulkenberg |  525 |  503 |   35 |   22 |  95.8% |  93.6% |     4.2% |     6.4% |
|         2023 Miami Race - Ocon |  460 |  378 |  245 |   82 |  82.1% |  60.6% |    17.9% |    39.4% |
|     2023 Miami Race - Hamilton | 1538 | 1457 | 3620 |   81 |  94.7% |  28.7% |     5.3% |    71.3% |
|       2023 Miami Race - Alonso | 1170 | 1128 |  149 |   42 |  96.5% |  88.3% |     3.5% |    11.7% |
|       2023 Miami Race - Bottas |  421 |  381 |  101 |   39 |  90.7% |  79.1% |     9.3% |    20.9% |
|      2023 Miami Race - Piastri |  867 |  808 | 1293 |   59 |  93.2% |  38.5% |     6.8% |    61.5% |

=> Aggregate stats 

Total speech duration  (P): 21271.0 sec
True positives        (TP): 19888.2 sec
False positives       (FP): 29282.6 sec
False negatives       (FN):  1382.8 sec    Min.    Avg.    Max. 
True positive rate   (TPR):    93.5%  |   79.4% / 92.6% / 98.6% 
Precision            (PPV):    40.4%  |   17.7% / 56.8% /100.0% 
False negative rate  (FNR):     6.5%  |    1.4% /  7.4% / 20.6% 
False discovery rate (FDR):    59.6%  |    0.0% / 43.2% / 82.3% 
F-Score (β =  0.70)       :    49.7% 
Fowlkes-Mallows index     :    61.5% 
```

# Cloning

This project uses Git submodules.

```bash
git clone --recursive https://github.com/recursiveGecko/formula-vad
```

# Dependencies

* Zig: `0.11.0 master`. Tested with `0.11.0-dev.3198+ad20236e9`.

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
