# Formula-VAD

Work in progress.

Project dedicated to audio analysis of F1 onboard streams for the purposes of radio transcription (& more coming soon).


# Current VAD results

As of `2023-06-08`.

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
|        2023 Monaco FP1 - Perez | 1036 | 1017 |   29 |   20 |  98.1% |  97.2% |     1.9% |     2.8% |
|     2023 Miami Race - Sargeant | 1108 | 1095 |   11 |   13 |  98.8% |  99.1% |     1.2% |     0.9% |
|        2023 Miami Race - Gasly | 1493 | 1463 |   73 |   30 |  98.0% |  95.2% |     2.0% |     4.8% |
|        2023 Miami Race - Perez |  971 |  931 |   11 |   40 |  95.9% |  98.9% |     4.1% |     1.1% |
|      2023 Miami Race - Leclerc | 1213 | 1213 |    0 |    1 |  99.9% | 100.0% |     0.1% |     0.0% |
|     2023 Miami Race - De Vries |  964 |  959 |    0 |    5 |  99.5% | 100.0% |     0.5% |     0.0% |
|         2023 Miami Race - Zhou | 1078 | 1063 |    6 |   15 |  98.6% |  99.5% |     1.4% |     0.5% |
|    2023 Miami Race - Magnussen |  986 |  964 |    7 |   22 |  97.8% |  99.3% |     2.2% |     0.7% |
|      2023 Miami Race - Russell | 1444 | 1415 |   11 |   30 |  97.9% |  99.2% |     2.1% |     0.8% |
|       2023 Miami Race - Norris |  503 |  501 |    0 |    2 |  99.6% | 100.0% |     0.4% |     0.0% |
|       2023 Miami Race - Stroll | 1091 | 1083 |   21 |    8 |  99.3% |  98.1% |     0.7% |     1.9% |
|      2023 Miami Race - Tsunoda |  655 |  649 |    0 |    5 |  99.2% | 100.0% |     0.8% |     0.0% |
|   2023 Miami Race - Verstappen | 1027 | 1012 |    0 |   15 |  98.6% | 100.0% |     1.4% |     0.0% |
|        2023 Miami Race - Sainz | 1443 | 1440 |   13 |    3 |  99.8% |  99.1% |     0.2% |     0.9% |
|        2023 Miami Race - Albon |  545 |  521 |   15 |   24 |  95.7% |  97.3% |     4.3% |     2.7% |
|   2023 Miami Race - Hulkenberg |  619 |  619 |   17 |    0 | 100.0% |  97.3% |     0.0% |     2.7% |
|         2023 Miami Race - Ocon |  605 |  600 |   78 |    5 |  99.2% |  88.5% |     0.8% |    11.5% |
|     2023 Miami Race - Hamilton | 1261 | 1240 |   10 |   21 |  98.3% |  99.2% |     1.7% |     0.8% |
|       2023 Miami Race - Alonso | 1162 | 1137 |    0 |   25 |  97.9% | 100.0% |     2.1% |     0.0% |
|       2023 Miami Race - Bottas |  579 |  578 |    0 |    1 |  99.9% | 100.0% |     0.1% |     0.0% |
|      2023 Miami Race - Piastri |  870 |  854 |    0 |   16 |  98.2% | 100.0% |     1.8% |     0.0% |

=> Aggregate stats 

Total speech duration  (P): 20652.7 sec
True positives        (TP): 20354.3 sec
False positives       (FP):   300.9 sec
False negatives       (FN):   298.5 sec    Min.    Avg.    Max. 
True positive rate   (TPR):    98.6%  |   95.7% / 98.6% /100.0% 
Precision            (PPV):    98.5%  |   88.5% / 98.5% /100.0% 
False negative rate  (FNR):     1.4%  |    0.0% /  1.4% /  4.3% 
False discovery rate (FDR):     1.5%  |    0.0% /  1.5% / 11.5% 
F-Score (β =  0.70)       :    98.5% 
Fowlkes-Mallows index     :    98.5% 

________________________________________________________
Executed in  387.73 secs    fish           external
   usr time  130.29 mins    0.00 micros  130.29 mins
   sys time    0.68 mins  336.00 micros    0.68 mins
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
