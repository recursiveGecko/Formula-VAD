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
|        2023 Monaco FP1 - Perez | 1132 | 1129 |    0 |    3 |  99.8% | 100.0% |     0.2% |     0.0% |
|     2023 Miami Race - Sargeant | 1072 | 1049 |    0 |   23 |  97.9% | 100.0% |     2.1% |     0.0% |
|        2023 Miami Race - Gasly | 1417 | 1318 |   22 |   99 |  93.0% |  98.3% |     7.0% |     1.7% |
|        2023 Miami Race - Perez | 1014 |  983 |    5 |   31 |  97.0% |  99.5% |     3.0% |     0.5% |
|      2023 Miami Race - Leclerc | 1203 | 1203 |    0 |    0 | 100.0% | 100.0% |     0.0% |     0.0% |
|     2023 Miami Race - De Vries |  949 |  937 |    0 |   12 |  98.7% | 100.0% |     1.3% |     0.0% |
|         2023 Miami Race - Zhou | 1076 | 1063 |    6 |   13 |  98.8% |  99.5% |     1.2% |     0.5% |
|    2023 Miami Race - Magnussen | 1018 | 1006 |    7 |   13 |  98.8% |  99.3% |     1.2% |     0.7% |
|      2023 Miami Race - Russell | 1431 | 1394 |    8 |   37 |  97.4% |  99.4% |     2.6% |     0.6% |
|       2023 Miami Race - Norris |  504 |  502 |    0 |    2 |  99.6% | 100.0% |     0.4% |     0.0% |
|       2023 Miami Race - Stroll | 1110 | 1104 |    0 |    6 |  99.5% | 100.0% |     0.5% |     0.0% |
|      2023 Miami Race - Tsunoda |  672 |  667 |    0 |    5 |  99.3% | 100.0% |     0.7% |     0.0% |
|   2023 Miami Race - Verstappen | 1032 | 1019 |    0 |   13 |  98.8% | 100.0% |     1.2% |     0.0% |
|        2023 Miami Race - Sainz | 1442 | 1432 |    8 |   10 |  99.3% |  99.4% |     0.7% |     0.6% |
|        2023 Miami Race - Albon |  544 |  516 |    1 |   28 |  94.9% |  99.9% |     5.1% |     0.1% |
|   2023 Miami Race - Hulkenberg |  611 |  611 |   17 |    0 | 100.0% |  97.2% |     0.0% |     2.8% |
|         2023 Miami Race - Ocon |  596 |  593 |   14 |    3 |  99.5% |  97.7% |     0.5% |     2.3% |
|     2023 Miami Race - Hamilton | 1256 | 1228 |   10 |   28 |  97.7% |  99.2% |     2.3% |     0.8% |
|       2023 Miami Race - Alonso | 1140 | 1114 |    0 |   27 |  97.6% | 100.0% |     2.4% |     0.0% |
|       2023 Miami Race - Bottas |  572 |  570 |    0 |    2 |  99.6% | 100.0% |     0.4% |     0.0% |
|      2023 Miami Race - Piastri |  756 |  680 |    0 |   75 |  90.0% | 100.0% |    10.0% |     0.0% |

=> Aggregate stats 

Total speech duration  (P): 20547.6 sec
True positives        (TP): 20118.3 sec
False positives       (FP):    98.7 sec
False negatives       (FN):   429.3 sec    Min.    Avg.    Max. 
True positive rate   (TPR):    97.9%  |   90.0% / 98.0% /100.0% 
Precision            (PPV):    99.5%  |   97.2% / 99.5% /100.0% 
False negative rate  (FNR):     2.1%  |    0.0% /  2.0% / 10.0% 
False discovery rate (FDR):     0.5%  |    0.0% /  0.5% /  2.8% 
F-Score (β =  0.70)       :    99.0% 
Fowlkes-Mallows index     :    98.7% 

________________________________________________________
Executed in  392.35 secs    fish           external
   usr time  132.74 mins    0.00 micros  132.74 mins
   sys time    0.55 mins  209.00 micros    0.55 mins
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
