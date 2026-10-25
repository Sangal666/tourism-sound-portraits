/*
Tourism Sound Portraits
Fixed-media sonification for the Kaggle "Tourism and Economic Impact Dataset"

Data-to-sound mapping:
- Tourist Arrivals       -> aircraft arrival/landing fixed-media sample density
- Tourism Receipts       -> money fixed-media sample density
- Tourism Expenditures   -> continuous coin-drop loop with dramatic amplitude
- Tourism Departures     -> aircraft cabin beep fixed-media sample density
- Average Length of Stay -> spaciousness / reverb, only if the CSV contains it

This script intentionally ignores GDP, unemployment, inflation, and other
non-tourism columns. Tourism departures is tourism-related and is included.
*/

(
// ================================================================
// 1. README-style settings
// ================================================================

// This fixed-media piece does not use audio input. Disabling input avoids
// sample-rate mismatch errors with Bluetooth devices and external microphones.
s.options.numInputBusChannels = 0;
s.options.numOutputBusChannels = 2;

~projectRoot = (PathName(thisProcess.nowExecutingPath).pathOnly +/+ "..").standardizePath;

~csvPath = (~projectRoot +/+ "data/world_tourism_economy_data.csv");
~outputDir = (~projectRoot +/+ "output");

// Fixed-media sample paths. Replace these if you rename or move the files.
~arrivalSamplePath = (~projectRoot +/+ "sample_assets/ucak kalkis.wav"); // aircraft landing/arrival sound
~moneySamplePath = (~projectRoot +/+ "sample_assets/money.wav");
~coinLoopSamplePath = (~projectRoot +/+ "sample_assets/coin drop loop yeni.wav");
~departureSamplePath = (~projectRoot +/+ "sample_assets/kabin beep.wav");

// Top countries from the 2019 tourist-arrivals list after removing countries
// without tourism receipts in the selected rows. Germany is included for 2019;
// its 2020 row is skipped because 2020 tourism receipts are missing.
// Removed for missing receipts in both selected rows: China, Spain, United Kingdom.
~countries = [
	"France", "United States", "Mexico",
	"Italy", "Poland", "Hungary",
	"Croatia", "Turkey", "Thailand", "Germany"
];

// The script tries this year first. If a country has no usable data for
// that year, it uses the latest available complete year for that country.
// Note: 2020 tourism values may reflect the COVID-19 pandemic; 2019 is
// closer to a pre-pandemic tourism baseline when a country falls back to it.
~targetYear = 2020;

// Batch comparison years. These are exact years: no fallback is used for the
// 2019/2020 comparison portraits.
~targetYears = [2019, 2020];

// Receipts are required. Arrivals/expenditures/departures can be partial: if one
// of those cells is missing, that sound layer stays silent and the post window reports it.
~allowPartialYearData = true;

// 20-30 seconds works well for the survey listening task.
~countryDur = 24;
~gapDur = 2;
~fadeDur = 2.5;

// Log normalization is useful because tourism values can differ by orders
// of magnitude. Set to false for linear normalization.
~useLogNormalization = true;

// Direct raw-data scales.
// These make the project explanation concrete:
// 1 aircraft sound = 10 million tourist arrivals
// 1 cabin beep = 5 million tourist departures
// 1 money sound = 10 billion tourism receipts
// coin loop amplitude = cubic curve of tourism expenditure / 5.0
~touristsPerArrivalSound = 10000000;
~touristsPerDepartureBeep = 5000000;
~receiptsPerMoneySound = 10000000000;
~expenditureUnitsForFullCoinLoop = 5.0;

// Pure fixed-media mode. Keep these false if you want to hear only the
// sample files controlled by tourism parameters.
~useBackgroundBed = false;
~useCountryMarker = false;

// Auto-run options. Leave false while editing; set one to true when you want
// the piece to start or render immediately after evaluating the whole file.
~autoPlayAllOnLoad = false;
~autoRecordEachCountryOnLoad = false;
~autoRecordCombinedOnLoad = false;

// Optional display-name -> CSV-name aliases. The included CSV uses "Turkiye".
~countryAliases = Dictionary[
	"Turkey" -> "Turkiye"
];


// ================================================================
// 2. CSV loading
// ================================================================

~cleanHeader = { |str|
	str.asString.stripWhiteSpace.toLower.replace(" ", "_").replace("-", "_");
};

~parseNumber = { |value|
	var txt = value.asString.stripWhiteSpace;
	if(txt.isEmpty or: { txt == "NA" } or: { txt == "NaN" }, {
		nil;
	}, {
		txt.interpret;
	});
};

~splitCSVLinePreserveEmptyCells = { |line|
	var cells, cell;
	cells = List.new;
	cell = String.new;

	line.do { |char|
		if(char == $,, {
			cells.add(cell);
			cell = String.new;
		}, {
			if((char != $\r) and: { char != $\n }, {
				cell = cell.add(char);
			});
		});
	};

	cells.add(cell);
	cells.asArray;
};

~readCSV = { |path|
	var text, table, headers, rows;

	// Important: String.split($,) removes empty cells in SuperCollider.
	// This custom splitter preserves empty CSV cells so columns stay aligned.
	text = File.readAllString(path);
	table = text.split($\n).collect { |line|
		~splitCSVLinePreserveEmptyCells.(line)
	}.select { |line|
		line.size > 1
	};
	headers = table[0].collect(~cleanHeader);
	rows = List.new;

	table.drop(1).do { |line|
		var row = Dictionary.new;
		headers.do { |header, i| row[header] = line[i] };
		rows.add(row);
	};

	("Loaded " ++ rows.size ++ " rows from: " ++ path).postln;
	("CSV columns: " ++ headers.join(", ")).postln;

	(rows: rows, headers: headers);
};

~csv = ~readCSV.(~csvPath);
~rows = ~csv[\rows];
~headers = ~csv[\headers];


// ================================================================
// 3. Country and year selection
// ================================================================

~columns = (
	country: "country",
	year: "year",
	arrivals: "tourism_arrivals",
	receipts: "tourism_receipts",
	expenditures: "tourism_expenditures",
	departures: "tourism_departures",
	stay: nil
);

// Only use Average Length of Stay if a matching column actually exists.
~stayAliases = [
	"average_length_of_stay",
	"avg_length_of_stay",
	"length_of_stay",
	"average_stay",
	"avg_stay"
];

~columns[\stay] = ~stayAliases.detect { |name| ~headers.includes(name) };

if(~columns[\stay].isNil, {
	"Average Length of Stay column not found. Using arrivals, receipts, expenditures, and departures.".postln;
}, {
	("Average Length of Stay column found: " ++ ~columns[\stay]).postln;
});


// ================================================================
// 4. Data cleaning
// ================================================================

~rowToData = { |row|
	(
		country: row[~columns[\country]].asString,
		year: ~parseNumber.(row[~columns[\year]]).asInteger,
		arrivals: ~parseNumber.(row[~columns[\arrivals]]),
		receipts: ~parseNumber.(row[~columns[\receipts]]),
		expenditures: ~parseNumber.(row[~columns[\expenditures]]),
		departures: ~parseNumber.(row[~columns[\departures]]),
		stay: if(~columns[\stay].isNil) { nil } { ~parseNumber.(row[~columns[\stay]]) }
	);
};

~hasRequiredTourismData = { |data|
	data[\arrivals].notNil and: {
		data[\receipts].notNil and: {
			data[\expenditures].notNil and: {
				data[\departures].notNil
			}
		}
	}
};

~missingTourismParams = { |data|
	var missing = List.new;
	if(data[\arrivals].isNil) { missing.add("tourist arrivals") };
	if(data[\receipts].isNil) { missing.add("tourism receipts") };
	if(data[\expenditures].isNil) { missing.add("tourism expenditures") };
	if(data[\departures].isNil) { missing.add("tourism departures") };
	missing.asArray;
};

~isUsableTourismRow = { |data|
	if(~allowPartialYearData) {
		data[\receipts].notNil
	} {
		~hasRequiredTourismData.(data)
	}
};

~selectCountryData = { |countryName|
	var matchingRows, countryRows, exact, latest, csvCountryName;

	csvCountryName = ~countryAliases[countryName] ? countryName;

	matchingRows = ~rows.select { |row| row[~columns[\country]].asString == csvCountryName };

	(countryName ++ ": found " ++ matchingRows.size ++ " CSV rows for " ++ csvCountryName).postln;

	countryRows = matchingRows
		.collect(~rowToData)
		.select(~isUsableTourismRow)
		.sort { |a, b| a[\year] < b[\year] };

	if(~allowPartialYearData) {
		(countryName ++ ": found " ++ countryRows.size ++ " rows with tourism receipts").postln;
	} {
		(countryName ++ ": found " ++ countryRows.size ++ " rows with arrivals + receipts + expenditures + departures").postln;
	};

	if(countryRows.isEmpty, {
		Error("No usable tourism rows found for " ++ countryName ++ " / CSV name: " ++ csvCountryName).throw;
	});

	exact = countryRows.detect { |data| data[\year] == ~targetYear };
	latest = exact ? countryRows.last;
	latest[\country] = countryName;
	latest[\csvCountry] = csvCountryName;
	latest[\missingParams] = ~missingTourismParams.(latest);

	if(exact.isNil, {
		(countryName ++ ": " ++ ~targetYear ++ " missing; using latest available year " ++ latest[\year]).postln;
	}, {
		(countryName ++ ": using selected year " ++ ~targetYear).postln;
	});

	if(latest[\missingParams].isEmpty.not) {
		("  Missing in selected row: " ++ latest[\missingParams].join(", ") ++ " -> silent layer(s)").postln;
	};

	latest;
};

~selectCountryYearData = { |countryName, year|
	var matchingRows, exactRow, data, csvCountryName, missing;

	csvCountryName = ~countryAliases[countryName] ? countryName;
	matchingRows = ~rows.select { |row| row[~columns[\country]].asString == csvCountryName };

	exactRow = matchingRows.detect { |row|
		~parseNumber.(row[~columns[\year]]).asInteger == year
	};

	if(exactRow.isNil) {
		("WARNING: no CSV row found for " ++ countryName ++ " / " ++ year).postln;
		nil;
	} {
		data = ~rowToData.(exactRow);
		data[\country] = countryName;
		data[\csvCountry] = csvCountryName;
		data[\missingParams] = ~missingTourismParams.(data);
		missing = data[\missingParams];

		if(~isUsableTourismRow.(data).not) {
			("WARNING: no usable tourism data found for " ++ countryName ++ " / " ++ year).postln;
			nil;
		} {
			if(missing.isEmpty.not) {
				("WARNING: " ++ countryName ++ " / " ++ year ++ " missing "
					++ missing.join(", ") ++ " -> silent layer(s)").postln;
			};
			data;
		};
	};
};

~countryYearData = List.new;
~countries.do { |countryName|
	~targetYears.do { |year|
		var data = ~selectCountryYearData.(countryName, year);
		if(data.notNil) { ~countryYearData.add(data) };
	};
};

~countryData = ~countryYearData.asArray;


// ================================================================
// 5. Parameter normalization
// ================================================================

~normalizeValues = { |items, key, useLog = true|
	var values, scaledValues, nonMissingValues, minVal, maxVal, norm;

	values = items.collect { |item|
		item[key];
	};

	scaledValues = values.collect { |value|
		var positiveValue;
		if(value.isNil) {
			nil;
		} {
			positiveValue = value.max(0);
			if(useLog) { log10(positiveValue + 1) } { positiveValue };
		}
	};

	nonMissingValues = scaledValues.select { |value| value.notNil };

	if(nonMissingValues.isEmpty) {
		norm = Array.fill(items.size, { 0 });
	} {
		minVal = nonMissingValues.minItem;
		maxVal = nonMissingValues.maxItem;

		norm = scaledValues.collect { |value|
			if(value.isNil) {
				0;
			} {
				if(maxVal == minVal) { 0.5 } { value.linlin(minVal, maxVal, 0, 1).clip(0, 1) };
			}
		};
	};

	norm;
};

~arrivalsNorm = ~normalizeValues.(~countryData, \arrivals, ~useLogNormalization);
~receiptsNorm = ~normalizeValues.(~countryData, \receipts, ~useLogNormalization);
~expendituresNorm = ~normalizeValues.(~countryData, \expenditures, ~useLogNormalization);
~departuresNorm = ~normalizeValues.(~countryData, \departures, ~useLogNormalization);

~stayNorm = if(~columns[\stay].notNil, {
	~normalizeValues.(~countryData, \stay, false);
}, {
	nil;
});

~portraits = ~countryData.collect { |data, i|
	var norm = (
		arrivals: ~arrivalsNorm[i],
		receipts: ~receiptsNorm[i],
		expenditures: ~expendituresNorm[i],
		departures: ~departuresNorm[i],
		stay: if(~stayNorm.isNil) { 0.35 } { ~stayNorm[i] }
	);

	(
		country: data[\country],
		year: data[\year],
		raw: data,
		norm: norm
	);
};

~printPortraitData = {
	"".postln;
	"================ Tourism Portrait Data ================".postln;
	~portraits.do { |portrait|
		var raw = portrait[\raw];
		var norm = portrait[\norm];

		("Country: " ++ portrait[\country] ++ " | Year used: " ++ portrait[\year]).postln;
		("  Tourist Arrivals raw: " ++ raw[\arrivals] ++ " | norm: " ++ norm[\arrivals].round(0.001)).postln;
		("  Tourism Receipts raw: " ++ raw[\receipts] ++ " | norm: " ++ norm[\receipts].round(0.001)).postln;
		("  Tourism Expenditures raw: " ++ raw[\expenditures] ++ " | norm: " ++ norm[\expenditures].round(0.001)).postln;
		("  Tourism Departures raw: " ++ raw[\departures] ++ " | norm: " ++ norm[\departures].round(0.001)).postln;
		if(raw[\missingParams].notNil and: { raw[\missingParams].isEmpty.not }) {
			("  Missing in CSV: " ++ raw[\missingParams].join(", ") ++ " -> silent layer(s)").postln;
		};

		if(~columns[\stay].notNil, {
			("  Average Length of Stay raw: " ++ raw[\stay] ++ " | norm: " ++ norm[\stay].round(0.001)).postln;
		});
		"".postln;
	};
	"=======================================================".postln;
};

~printPortraitData.();


// ================================================================
// 6. SynthDefs
// ================================================================

s.waitForBoot {
	"Loading fixed-media samples...".postln;
	~arrivalBuf = Buffer.read(s, ~arrivalSamplePath);
	~moneyBuf = Buffer.read(s, ~moneySamplePath);
	~coinLoopBuf = Buffer.read(s, ~coinLoopSamplePath);
	~departureBuf = Buffer.read(s, ~departureSamplePath);
	s.sync;
	("  arrivals sample: " ++ ~arrivalSamplePath).postln;
	("  money sample: " ++ ~moneySamplePath).postln;
	("  coin loop sample: " ++ ~coinLoopSamplePath).postln;
	("  departure sample: " ++ ~departureSamplePath).postln;

	SynthDef(\tourismBed, { |out = 0, amp = 0.08, dur = 24, fade = 2, baseFreq = 160,
		arrivals = 0.5, receipts = 0.5, stay = 0.35|
		var env, src, shimmer, cutoff, wet, sig;

		env = EnvGen.kr(Env.linen(fade, (dur - (fade * 2)).max(0.1), fade, amp, \sin), doneAction: 2);

		// Neutral soft bed. Receipts are handled by the money sample layer.
		cutoff = 1800;

		src = Mix.fill(5, { |i|
			var detune = LFNoise1.kr(0.08 + (i * 0.03)).range(-0.018, 0.018);
			var partial = [1, 1.5, 2, 2.5, 3][i];
			SinOsc.ar(baseFreq * partial * (1 + detune), 0, 0.18 / (i + 1));
		});

		shimmer = BPF.ar(WhiteNoise.ar(0.018), cutoff * [0.7, 1, 1.35], 0.08).sum;
		sig = LPF.ar(src + shimmer, cutoff);

		// Average Length of Stay, if available -> larger reverb space.
		// If unavailable, a gentle default is used.
		wet = stay.linlin(0, 1, 0.16, 0.48);
		sig = FreeVerb2.ar(sig, DelayC.ar(sig, 0.03, 0.012), wet, stay.linlin(0, 1, 0.45, 0.88), 0.38);

		Out.ar(out, Pan2.ar(sig * env, LFNoise1.kr(0.05).range(-0.25, 0.25)));
	}).add;

	SynthDef(\tourismSampleStereo, { |out = 0, buf = 0, amp = 0.15, pan = 0, rate = 1,
		startPos = 0, fadeIn = 0.01, fadeOut = 0.08|
		var frames, dur, env, sig;
		frames = BufFrames.kr(buf);
		dur = (frames - startPos).max(1) / (BufSampleRate.kr(buf) * rate.abs.max(0.01));
		env = EnvGen.kr(Env.linen(fadeIn, dur.max(0.05), fadeOut, amp, \sin), doneAction: 2);
		sig = PlayBuf.ar(2, buf, BufRateScale.kr(buf) * rate, startPos: startPos, doneAction: 0);
		sig = LeakDC.ar(sig);
		sig = Balance2.ar(sig[0], sig[1], pan, env);
		Out.ar(out, sig);
	}).add;

	SynthDef(\tourismSampleMono, { |out = 0, buf = 0, amp = 0.15, pan = 0, rate = 1,
		startPos = 0, fadeIn = 0.01, fadeOut = 0.08|
		var frames, dur, env, sig;
		frames = BufFrames.kr(buf);
		dur = (frames - startPos).max(1) / (BufSampleRate.kr(buf) * rate.abs.max(0.01));
		env = EnvGen.kr(Env.linen(fadeIn, dur.max(0.05), fadeOut, amp, \sin), doneAction: 2);
		sig = PlayBuf.ar(1, buf, BufRateScale.kr(buf) * rate, startPos: startPos, doneAction: 0);
		sig = LeakDC.ar(sig);
		Out.ar(out, Pan2.ar(sig * env, pan));
	}).add;

	SynthDef(\tourismLoopStereo, { |out = 0, buf = 0, amp = 0.12, pan = 0, rate = 1, dur = 24, fade = 2|
		var env, frames, phase, sig;
		env = EnvGen.kr(Env.linen(fade, (dur - (fade * 2)).max(0.1), fade, amp, \sin), doneAction: 2);
		frames = BufFrames.kr(buf);
		phase = Phasor.ar(
			trig: 0,
			rate: BufRateScale.kr(buf) * rate,
			start: 0,
			end: frames,
			resetPos: 0
		);
		sig = BufRd.ar(2, buf, phase, loop: 1, interpolation: 2);
		sig = LeakDC.ar(sig);
		sig = Balance2.ar(sig[0], sig[1], pan, env);
		Out.ar(out, sig);
	}).add;

	SynthDef(\tourismMarker, { |out = 0, amp = 0.06, freq = 440|
		var env, sig;
		env = EnvGen.kr(Env.perc(0.02, 1.4, amp, curve: -4), doneAction: 2);
		sig = SinOsc.ar(freq * [1, 1.005], 0, env).sum * 0.5;
		sig = FreeVerb.ar(sig, 0.25, 0.7, 0.4);
		Out.ar(out, Pan2.ar(sig, 0));
	}).add;

	s.sync;


	// ================================================================
	// 7. Function to play one country
	// ================================================================

	~playOneCountry = { |portrait, dur|
		var norm = portrait[\norm];
		var arrivals = norm[\arrivals];
		var receipts = norm[\receipts];
		var departures = norm[\departures];
		var stay = norm[\stay];
		var raw = portrait[\raw];
		var rawArrivals, rawReceipts, rawExpenditures, rawDepartures;
		var baseFreq, arrivalEventCount, departureEventCount, moneyEventCount;
		var arrivalInterval, departureInterval, moneyInterval;
		var arrivalAmp, moneyAmp, departureAmp;
		var coinLoopAmount, coinLoopCurve, coinLoopAmp;

		dur = dur ? ~countryDur;
		baseFreq = portrait[\country].ascii.sum.linlin(500, 1300, 135, 230).clip(120, 260);
		rawArrivals = raw[\arrivals] ? 0;
		rawReceipts = raw[\receipts] ? 0;
		rawExpenditures = raw[\expenditures] ? 0;
		rawDepartures = raw[\departures] ? 0;

		// Direct raw-data scale:
		// 1 aircraft sound = ~touristsPerArrivalSound tourist arrivals.
		// 1 cabin beep = ~touristsPerDepartureBeep tourist departures.
		// 1 money sound = ~receiptsPerMoneySound tourism receipts.
		arrivalEventCount = (rawArrivals / ~touristsPerArrivalSound).round(1).asInteger.max(0);
		departureEventCount = (rawDepartures / ~touristsPerDepartureBeep).round(1).asInteger.max(0);
		moneyEventCount = (rawReceipts / ~receiptsPerMoneySound).round(1).asInteger.max(0);
		coinLoopAmount = (rawExpenditures / ~expenditureUnitsForFullCoinLoop).clip(0, 1);
		coinLoopCurve = coinLoopAmount * coinLoopAmount * coinLoopAmount;

		arrivalInterval = (dur - 1.0).max(1) / arrivalEventCount.max(1);
		departureInterval = (dur - 0.8).max(1) / departureEventCount.max(1);
		moneyInterval = (dur - 1.0).max(1) / moneyEventCount.max(1);

		arrivalAmp = arrivals.linlin(0, 1, 0.08, 0.22);
		moneyAmp = receipts.linlin(0, 1, 0.05, 0.18);
		departureAmp = departures.linlin(0, 1, 0.055, 0.16);
		coinLoopAmp = coinLoopCurve.linlin(0, 1, 0.004, 0.34);

		("Playing " ++ portrait[\country] ++ " (" ++ portrait[\year] ++ ")").postln;
		("  1 aircraft sound = " ++ ~touristsPerArrivalSound.asInteger ++ " arrivals"
			++ " | aircraft sounds: " ++ arrivalEventCount
			++ " | 1 beep = " ++ ~touristsPerDepartureBeep.asInteger ++ " departures"
			++ " | beeps: " ++ departureEventCount
			++ " | 1 money sound = " ++ ~receiptsPerMoneySound.asInteger ++ " receipts"
			++ " | money sounds: " ++ moneyEventCount
			++ " | expenditure coin loop amount: " ++ coinLoopAmount.round(0.001)
			++ " | coin loop amp: " ++ coinLoopAmp.round(0.001)
			++ " | space: " ++ stay.round(0.001)).postln;

		if(raw[\missingParams].notNil and: { raw[\missingParams].isEmpty.not }) {
			("  Missing data layer(s) are silent: " ++ raw[\missingParams].join(", ")).postln;
		};

		if(~useCountryMarker) {
			Synth(\tourismMarker, [\freq, baseFreq * 2, \amp, 0.035]);
		};

		if(~useBackgroundBed) {
			Synth(\tourismBed, [
				\dur, dur,
				\fade, ~fadeDur,
				\baseFreq, baseFreq,
				\arrivals, arrivals,
				\receipts, receipts,
				\stay, stay,
				\amp, 0.065
			]);
		};

		if(arrivalEventCount > 0, {
			// Tourist Arrivals -> aircraft arrival/landing fixed-media sample.
			Pbind(
				\instrument, \tourismSampleStereo,
				\buf, ~arrivalBuf.bufnum,
				\dur, Pseq(Array.fill(arrivalEventCount, { arrivalInterval }), 1),
				\rate, Pwhite(0.92, 1.08),
				\pan, Pwhite(-0.35, 0.35),
				\amp, Pwhite(arrivalAmp * 0.65, arrivalAmp)
			).play(quant: 0);
		});

		if(coinLoopAmount > 0, {
			// Tourism Expenditures -> continuous coin-drop loop.
			// Amplitude uses a cubic curve, so low expenditure stays subtle
			// and high expenditure becomes dramatically louder.
			Synth(\tourismLoopStereo, [
				\buf, ~coinLoopBuf.bufnum,
				\dur, dur,
				\fade, ~fadeDur,
				\rate, coinLoopAmount.linlin(0, 1, 0.92, 1.08),
				\pan, coinLoopCurve.linlin(0, 1, -0.18, 0.18),
				\amp, coinLoopAmp
			]);
		});

		if(moneyEventCount > 0, {
			// Tourism Receipts -> fixed-media money/cash sample.
			Pbind(
				\instrument, \tourismSampleStereo,
				\buf, ~moneyBuf.bufnum,
				\dur, Pseq(Array.fill(moneyEventCount, { moneyInterval }), 1),
				\rate, Pwhite(0.95, 1.12),
				\startPos, Pwhite(0, (~moneyBuf.numFrames * 0.55).asInteger),
				\pan, Pwhite(-0.65, 0.65),
				\amp, Pwhite(moneyAmp * 0.55, moneyAmp)
			).play(quant: 0);
		});

		if(departureEventCount > 0, {
			// Tourism Departures -> aircraft cabin beep fixed-media sample.
			Pbind(
				\instrument, \tourismSampleMono,
				\buf, ~departureBuf.bufnum,
				\dur, Pseq(Array.fill(departureEventCount, { departureInterval }), 1),
				\rate, Pwhite(0.98, 1.04),
				\pan, Pseq([-0.75, 0.75, -0.25, 0.25], inf),
				\amp, Pwhite(departureAmp * 0.65, departureAmp)
			).play(quant: 0);
		});
	};


	// ================================================================
	// 8. Function to play all countries in sequence
	// ================================================================

	~playAllCountries = {
		Routine({
			~portraits.do { |portrait, i|
				~playOneCountry.(portrait, ~countryDur);
				(~countryDur + ~gapDur).wait;
			};
			"Finished all tourism sound portraits.".postln;
		}).play;
	};

	~portraitsForYear = { |year|
		~portraits.select { |portrait| portrait[\year] == year };
	};

	~playAllCountriesForYear = { |year|
		Routine({
			var selected = ~portraitsForYear.(year);
			selected.do { |portrait, i|
				~playOneCountry.(portrait, ~countryDur);
				(~countryDur + ~gapDur).wait;
			};
			("Finished tourism sound portraits for " ++ year ++ ".").postln;
		}).play;
	};


	// ================================================================
	// 9. Recording/export section
	// ================================================================

	~safeFileName = { |name|
		name.asString.toLower.replace(" ", "_").replace("/", "_");
	};

	~ensureOutputDir = {
		var path = PathName(~outputDir);
		if(path.isFolder.not) {
			("mkdir -p \"" ++ ~outputDir ++ "\"").unixCmd;
		};
	};

	~recordOneCountry = { |portrait|
		var file;
		~ensureOutputDir.();
		file = ~outputDir +/+ (~safeFileName.(portrait[\country]) ++ "_" ++ portrait[\year] ++ ".wav");

		Routine({
			("Recording: " ++ file).postln;
			s.prepareForRecord(file, numChannels: 2);
			0.2.wait;
			s.record;
			0.2.wait;
			~playOneCountry.(portrait, ~countryDur);
			(~countryDur + 0.8).wait;
			s.stopRecording;
			("Saved: " ++ file).postln;
		}).play;
	};

	~recordAllCountries = {
		var file, totalDur, yearLabel;
		~ensureOutputDir.();
		yearLabel = ~targetYears.collect { |year| year.asString }.join("_");
		file = ~outputDir +/+ ("tourism_portraits_combined_" ++ yearLabel ++ ".wav");
		totalDur = (~countryDur + ~gapDur) * ~portraits.size;

		Routine({
			("Recording combined file: " ++ file).postln;
			s.prepareForRecord(file, numChannels: 2);
			0.2.wait;
			s.record;
			0.2.wait;
			~playAllCountries.();
			(totalDur + 1.0).wait;
			s.stopRecording;
			("Saved combined file: " ++ file).postln;
		}).play;
	};

	~recordCombinedForYear = { |year|
		var file, selected, totalDur;
		~ensureOutputDir.();
		selected = ~portraitsForYear.(year);
		file = ~outputDir +/+ ("tourism_portraits_combined_" ++ year ++ ".wav");
		totalDur = (~countryDur + ~gapDur) * selected.size;

		Routine({
			("Recording combined file for " ++ year ++ ": " ++ file).postln;
			s.prepareForRecord(file, numChannels: 2);
			0.2.wait;
			s.record;
			0.2.wait;
			selected.do { |portrait|
				~playOneCountry.(portrait, ~countryDur);
				(~countryDur + ~gapDur).wait;
			};
			1.0.wait;
			s.stopRecording;
			("Saved combined file for " ++ year ++ ": " ++ file).postln;
		}).play;
	};

	~recordEachCountryNow = {
		Routine({
			~portraits.do { |portrait|
				~recordOneCountry.(portrait);
				(~countryDur + 2.5).wait;
			};
			"Finished individual country recordings.".postln;
		}).play;
	};

	~recordAllYearBatchesNow = {
		Routine({
			~targetYears.do { |year|
				var selected = ~portraitsForYear.(year);
				~recordCombinedForYear.(year);
				(((~countryDur + ~gapDur) * selected.size) + 2.5).wait;
			};
			"Finished combined recordings for all target years.".postln;
		}).play;
	};

	"
Ready.

Try these commands:
~playOneCountry.(~portraits[0]);   // play first country in ~countries
~playAllCountries.();              // play all selected countries in sequence
~playAllCountriesForYear.(2019);   // play only the 2019 portraits
~playAllCountriesForYear.(2020);   // play only the 2020 portraits
~recordOneCountry.(~portraits[0]); // export one country
~recordEachCountryNow.();          // export separate WAV files for all country-year portraits
~recordCombinedForYear.(2019);     // export one combined 2019 WAV file
~recordCombinedForYear.(2020);     // export one combined 2020 WAV file
~recordAllCountries.();            // export one combined WAV file for all years
~recordAllYearBatchesNow.();       // export 2019 combined, then 2020 combined
	".postln;

	if(~autoPlayAllOnLoad) {
		~playAllCountries.();
	};

	if(~autoRecordEachCountryOnLoad) {
		~recordEachCountryNow.();
	};

	if(~autoRecordCombinedOnLoad) {
		~recordAllCountries.();
	};
};
)
