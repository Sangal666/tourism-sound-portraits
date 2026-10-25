# Tourism Sound Portraits

A data sonification project that turns annual tourism statistics into 24-second sound portraits. Python and SuperCollider map arrivals, receipts, expenditure and departures to layers of aircraft, cash, coins and cabin beeps.

**Listen:** [France 2019](media/france_2019.wav) · [France 2020](media/france_2020.wav)

These are existing rendered examples. The project compares 2019 and 2020 across selected countries; missing tourism layers remain silent.

## Data to sound

| Tourism indicator | Sound mapping |
| --- | --- |
| Arrivals | One aircraft event per 10 million arrivals |
| Receipts | One cash event per 10 billion receipts |
| Expenditure | Continuous coin-loop level with a cubic intensity curve |
| Departures | One cabin beep per 5 million departures |

## Run the Python renderer

Requires Python 3.10+ and NumPy. From the repository root:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python code/render_tourism_portraits_2019_2020_with_expenditures.py
```

On Windows, activate the environment and use `python` for the same script. Individual portraits, combined comparisons and a text rendering report are written to `output/`. Input samples are included as PCM WAV; no browser or MP3 decoder is needed.

## SuperCollider

Open and evaluate `code/tourism_sound_portraits_with_expenditures.scd` in SuperCollider. Paths resolve relative to the saved script. For a year comparison, use `~playAllCountriesForYear.(2019);` or `~playAllCountriesForYear.(2020);`. SuperCollider playback has not been rechecked during repository preparation.

## Project files

- `code/`: Python offline renderer and SuperCollider version.
- `data/`: the original tourism CSV used by the project.
- `sample_assets/`: source sounds.
- `media/`: two original rendered examples.

The source CSV is identified in the original project as the Kaggle “Tourism and Economic Impact Dataset”. Expenditure is treated as a relative intensity measure, not directly subtracted from receipts. Sound-sample and dataset redistribution terms should be confirmed before public release.

The Python renderer was checked during preparation: 19 individual portraits and three combined WAVs were generated successfully; duration, channel format and non-silent output checks passed.
