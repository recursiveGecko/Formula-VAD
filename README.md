# Formula-VAD

Work in progress.

Project dedicated to audio analysis of F1 onboard streams for the purposes of radio transcription (& more coming soon).


# Current VAD results

As of `2023-05-23`.

```
=> Definitions

P   (Positives):                            Total number of real speech segments (from reference labels)
TP  (True positives):                       Number of correctly detected speech segments
FP  (False positives):                      Number of incorrectly detected speech segments
FN  (False negatives):                      Number of missed speech segments
TPR (True positive rate, sensitivity):      Probability that VAD detects a real speech segment. = TP / P 
FNR (False negative rate, miss rate):       Probability that VAD misses a speech segment.       = FN / P 
PPV (Precision, Positive predictive value): Probability that detected speech segment is true.   = TP / (TP + FP) 
FDR (False discovery rate):                 Probability that detected speech segment is false.  = FP / (TP + FP) 

=> Performance Report

|                           Name |   P |  TP |  FP |  FN |    TPR |    FNR |    PPV |  FDR (!) |
| ------------------------------ | --- | --- | --- | --- | ------ | ------ | ------ | -------- |
|                         Stroll | 196 | 192 |   0 |   4 |  98.0% |   2.0% | 100.0% |     0.0% |
|                        Tsunoda | 137 | 119 |   0 |  18 |  86.9% |  13.1% | 100.0% |     0.0% |
|                     Verstappen | 202 | 179 |   0 |  23 |  88.6% |  11.4% | 100.0% |     0.0% |
|                          Sainz | 216 | 206 |  13 |  10 |  95.4% |   4.6% |  94.1% |     5.9% |
|                          Albon | 124 | 119 |   5 |   5 |  96.0% |   4.0% |  96.0% |     4.0% |
|                     Hulkenberg |  74 |  72 |   4 |   2 |  97.3% |   2.7% |  94.7% |     5.3% |
|                           Ocon |  96 |  93 |  12 |   3 |  96.9% |   3.1% |  88.6% |    11.4% |
|                       Hamilton | 206 | 100 |   1 | 106 |  48.5% |  51.5% |  99.0% |     1.0% |
|                         Alonso | 216 | 195 |   0 |  21 |  90.3% |   9.7% | 100.0% |     0.0% |
|                         Bottas |  93 |  90 |   0 |   3 |  96.8% |   3.2% | 100.0% |     0.0% |
|                        Piastri | 144 |  68 |   0 |  76 |  47.2% |  52.8% | 100.0% |     0.0% |

=> Aggregate stats 

Total speech events    (P):  1704
True positives        (TP):  1433
False positives       (FP):    35
False negatives       (FN):   271          Min.    Avg.    Max. 
True positive rate   (TPR):    84.1%  |   47.2% / 85.6% / 98.0% 
False negative rate  (FNR):    15.9%  |    2.0% / 14.4% / 52.8% 
Precision            (PPV):    97.6%  |   88.6% / 97.5% /100.0% 
False discovery rate (FDR):     2.4%  |    0.0% /  2.5% / 11.4% 
F-Score (β =  0.70)       :    92.7% 
Fowlkes-Mallows index     :    90.6% 
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
