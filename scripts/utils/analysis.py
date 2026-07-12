import logging
import os
import time

import librosa
import numpy as np
from scipy.signal import butter, sosfiltfilt

from .classes import Detection, ParseFileName
from .helpers import get_settings, get_language
from .models import get_model

log = logging.getLogger(__name__)

MODEL = None


def _config_float(conf, key, default=0.0):
    """Read an optional numeric setting without breaking older config files."""
    try:
        return conf.getfloat(key)
    except (KeyError, ValueError):
        return default


def _config_int(conf, key, default=0):
    try:
        return conf.getint(key)
    except (KeyError, ValueError, TypeError):
        return default


def filter_detection_candidates(raw_detections, occurrence_scores, conf):
    """Apply a generic multi-signal confirmation filter to model candidates.

    The filter deliberately works on evidence rather than named species.  A
    candidate is easier to accept when it is geographically common, repeated
    in multiple analysis windows, clearly ahead of the runner-up, or extremely
    confident.  This is a post-classification filter; it never alters audio.
    """
    mode = str(conf.get('DETECTION_FILTER_MODE', 'off')).strip().lower()
    if mode in ('', 'off', '0', 'false', 'disabled'):
        return raw_detections

    base_confidence = conf.getfloat('CONFIDENCE')
    min_hits = max(1, _config_int(conf, 'DETECTION_MIN_HITS', 2))
    rare_min_hits = max(min_hits, _config_int(conf, 'DETECTION_RARE_MIN_HITS', 3))
    rare_occurrence = max(0.0, _config_float(conf, 'DETECTION_RARE_OCCURRENCE', 0.08))
    high_confidence = max(base_confidence, _config_float(conf, 'DETECTION_HIGH_CONFIDENCE', 0.97))
    min_margin = max(0.0, _config_float(conf, 'DETECTION_MIN_MARGIN', 0.10))

    evidence = {}
    top_by_slot = {}
    for time_slot, entries in raw_detections.items():
        if not entries:
            continue
        top_name, top_confidence = entries[0]
        runner_up = entries[1][1] if len(entries) > 1 else 0.0
        top_by_slot[time_slot] = (top_name, float(top_confidence), float(top_confidence) - float(runner_up))
        if top_confidence >= base_confidence:
            evidence.setdefault(top_name, []).append(top_by_slot[time_slot])

    accepted_species = set()
    for sci_name, hits in evidence.items():
        occurrence = occurrence_scores.get(sci_name)
        required_hits = rare_min_hits if occurrence is not None and occurrence < rare_occurrence else min_hits
        best_confidence = max(hit[1] for hit in hits)
        best_margin = max(hit[2] for hit in hits)
        repeated = len(hits) >= required_hits
        exceptional_single = best_confidence >= high_confidence and best_margin >= min_margin
        if repeated or exceptional_single:
            accepted_species.add(sci_name)
        else:
            log.info(
                'Confirmation filter rejected %s: hits=%d/%d, max_confidence=%.4f, '
                'max_margin=%.4f, occurrence=%s',
                sci_name, len(hits), required_hits, best_confidence, best_margin,
                'unknown' if occurrence is None else f'{occurrence:.4f}',
            )

    filtered = {}
    for time_slot, entries in raw_detections.items():
        # Once a species has enough file-level evidence, retain all of its
        # above-threshold windows so reporting and extraction keep their timing.
        kept = [entry for entry in entries
                if entry[0] in accepted_species and entry[1] >= base_confidence]
        if kept:
            filtered[time_slot] = kept
    return filtered


def apply_analysis_filter(sig, rate, highpass_hz=0.0, lowpass_hz=0.0):
    """Apply an optional, zero-phase band-pass filter before BirdNET inference.

    The recording on disk is never changed.  Keeping this operation in memory
    makes it possible to remove low-frequency rumble and high-frequency hiss
    without losing the original WAV used for evidence and playback extraction.
    """
    highpass_hz = float(highpass_hz)
    lowpass_hz = float(lowpass_hz)
    nyquist = rate / 2.0

    if highpass_hz <= 0 and lowpass_hz <= 0:
        return sig
    if highpass_hz < 0 or lowpass_hz < 0:
        log.warning('Analysis filter frequencies must be non-negative; skipping filter')
        return sig
    if highpass_hz >= nyquist or (lowpass_hz and lowpass_hz >= nyquist):
        log.warning('Analysis filter frequency must be below %.0f Hz; skipping filter', nyquist)
        return sig
    if highpass_hz and lowpass_hz and highpass_hz >= lowpass_hz:
        log.warning('ANALYSIS_HIGHPASS_HZ must be lower than ANALYSIS_LOWPASS_HZ; skipping filter')
        return sig

    if highpass_hz and lowpass_hz:
        filter_type = 'bandpass'
        cutoff = [highpass_hz, lowpass_hz]
    elif highpass_hz:
        filter_type = 'highpass'
        cutoff = highpass_hz
    else:
        filter_type = 'lowpass'
        cutoff = lowpass_hz

    try:
        sos = butter(4, cutoff, btype=filter_type, fs=rate, output='sos')
        return sosfiltfilt(sos, sig).astype(sig.dtype, copy=False)
    except ValueError as exc:
        # Do not allow a malformed optional filter setting to stop detection.
        log.warning('Unable to apply analysis filter: %s', exc)
        return sig


def loadCustomSpeciesList(path):
    species_list = []
    if os.path.isfile(path):
        with open(path, 'r') as csfile:
            species_list = [line.strip().split('_')[0] for line in csfile.readlines()]

    return species_list


def splitSignal(sig, rate, overlap, seconds=3.0, minlen=1.5):
    # Split signal with overlap
    sig_splits = []
    for i in range(0, len(sig), int((seconds - overlap) * rate)):
        split = sig[i:i + int(seconds * rate)]

        # End of signal?
        if len(split) < int(minlen * rate):
            break

        # Signal chunk too short? Fill with zeros.
        if len(split) < int(rate * seconds):
            temp = np.zeros((int(rate * seconds)))
            temp[:len(split)] = split
            split = temp

        sig_splits.append(split)

    return sig_splits


def readAudioData(path, overlap, sample_rate, chunk_duration):
    log.info('READING AUDIO DATA...')

    # Open file with librosa (uses ffmpeg or libav)
    sig, rate = librosa.load(path, sr=sample_rate, mono=True, res_type='kaiser_fast')

    conf = get_settings()
    highpass_hz = _config_float(conf, 'ANALYSIS_HIGHPASS_HZ')
    lowpass_hz = _config_float(conf, 'ANALYSIS_LOWPASS_HZ')
    if highpass_hz or lowpass_hz:
        log.info('Applying analysis filter: high-pass=%s Hz, low-pass=%s Hz', highpass_hz, lowpass_hz)
        sig = apply_analysis_filter(sig, rate, highpass_hz, lowpass_hz)

    # Split audio into chunks
    chunks = splitSignal(sig, rate, overlap, seconds=chunk_duration)

    log.info('READING DONE! READ %d CHUNKS.', len(chunks))

    return chunks


def analyzeAudioData(chunks, overlap, lat, lon, week):
    detections = []
    model = load_global_model()

    start = time.time()
    log.info('ANALYZING AUDIO...')

    model.set_meta_data(lat, lon, week)
    predicted_species_list = model.get_species_list()

    # Parse every chunk
    for chunk in chunks:
        p = model.predict(chunk)
        log.debug("PPPPP: %s", p)
        detections.append(p)

    labeled = {}
    pred_start = 0.0
    for p in filter_humans(detections):
        # Save timestamp and result
        pred_end = pred_start + model.chunk_duration
        labeled[str(pred_start) + ';' + str(pred_end)] = p

        pred_start = pred_end - overlap

    log.info('DONE! Time %.2f SECONDS', time.time() - start)
    return labeled, predicted_species_list


def filter_humans(predictions):
    conf = get_settings()
    priv_thresh = conf.getfloat('PRIVACY_THRESHOLD')
    human_cutoff = max(10, int(6000 * priv_thresh / 100.0))
    log.debug("HUMAN-CUTOFF AT: %d", human_cutoff)
    try:
        if conf.getint('EXTRACTION_LENGTH') > 9:
            log.warning("EXTRACTION_LENGTH is set to %d. Privacy filter might miss human sound, "
                        "if you care about privacy, set EXTRACTION_LENGTH to below 9 or leave empty.", conf.getint('EXTRACTION_LENGTH'))
    except ValueError:
        pass

    # mask for humans
    human_mask = [False] * len(predictions)
    for i, prediction in enumerate(predictions):
        for p in prediction[:human_cutoff]:
            if 'Human' in p[0]:
                human_mask[i] = True
                break

    # mask for predictions that have a human neighbour
    human_neighbour_mask = [False] * len(predictions)
    for i, _ in enumerate(human_mask):
        if i != 0 and human_mask[i - 1]:
            human_neighbour_mask[i] = True
        if i != len(human_mask) - 1 and human_mask[i + 1]:
            human_neighbour_mask[i] = True

    clean_detections = []
    for prediction, human, has_human_neighbour in zip(predictions, human_mask, human_neighbour_mask):
        if human or has_human_neighbour:
            log.debug('Overwriting prediction %s', prediction[0])
            prediction = [('Human_Human', 0.0)]
        else:
            prediction = prediction[:10]
        clean_detections.append(prediction)

    return clean_detections


def load_global_model():
    global MODEL
    if MODEL is None:
        log.info('LOADING TF LITE MODEL...')
        MODEL = get_model()
        log.info('LOADING DONE!')

    return MODEL


def run_analysis(file):
    include_list = loadCustomSpeciesList(os.path.expanduser("~/BirdNET-Pi/include_species_list.txt"))
    exclude_list = loadCustomSpeciesList(os.path.expanduser("~/BirdNET-Pi/exclude_species_list.txt"))
    whitelist_list = loadCustomSpeciesList(os.path.expanduser("~/BirdNET-Pi/whitelist_species_list.txt"))

    conf = get_settings()
    model = load_global_model()
    names = get_language(conf['DATABASE_LANG'])

    # Read audio data & handle errors
    try:
        audio_data = readAudioData(file.file_name, conf.getfloat('OVERLAP'), model.sample_rate, model.chunk_duration)
    except (NameError, TypeError) as e:
        log.error("Error with the following info: %s", e)
        return []

    # Process audio data and get detections
    raw_detections, predicted_species_list = analyzeAudioData(audio_data, conf.getfloat('OVERLAP'), conf.getfloat('LATITUDE'),
                                                              conf.getfloat('LONGITUDE'), file.week)
    raw_detections = filter_detection_candidates(
        raw_detections,
        model.get_species_occurrence_scores(),
        conf,
    )
    confident_detections = []
    for time_slot, entries in raw_detections.items():
        sci_name, confidence = entries[0]
        log.info('%s-(%s_%s, %s)', time_slot, sci_name, names.get(sci_name, sci_name), confidence)
        for sci_name, confidence in entries:
            if confidence >= conf.getfloat('CONFIDENCE'):
                com_name = names.get(sci_name, sci_name)
                if sci_name not in include_list and len(include_list) != 0:
                    log.warning("Excluded as INCLUDE_LIST is active but this species is not in it: %s %s", sci_name, com_name)
                elif sci_name in exclude_list and len(exclude_list) != 0:
                    log.warning("Excluded as species in EXCLUDE_LIST: %s %s", sci_name, com_name)
                elif sci_name not in predicted_species_list and len(predicted_species_list) != 0 and sci_name not in whitelist_list:
                    log.warning("Excluded as below Species Occurrence Frequency Threshold: %s %s", sci_name, com_name)
                else:
                    d = Detection(
                        file.file_date,
                        time_slot.split(';')[0],
                        time_slot.split(';')[1],
                        sci_name,
                        com_name,
                        confidence,
                    )
                    confident_detections.append(d)
    return confident_detections


if __name__ == '__main__':
    conf = get_settings()
    model = conf['MODEL']
    test_files = ['../tests/testdata/2024-02-24-birdnet-16:19:37.wav']
    results = [{
        "BirdNET_6K_GLOBAL_MODEL": [
            {"confidence": 0.9894, 'sci_name': 'Pica pica'},
            {"confidence": 0.9779, 'sci_name': 'Pica pica'},
            {"confidence": 0.9943, 'sci_name': 'Pica pica'}],
        "BirdNET_GLOBAL_6K_V2.4_Model_FP16": [
            {"confidence": 0.912, 'sci_name': 'Pica pica'},
            {"confidence": 0.9316, 'sci_name': 'Pica pica'},
            {"confidence": 0.8857, 'sci_name': 'Pica pica'}],
        "Perch_v2": [
            {"confidence": 0.9641, 'sci_name': 'Pica pica'},
            {"confidence": 0.9609, 'sci_name': 'Pica pica'},
            {"confidence": 0.9468, 'sci_name': 'Pica pica'}],
        "BirdNET-Go_classifier_20250916": [
            {"confidence": 0.9123, 'sci_name': 'Pica pica'},
            {"confidence": 0.9317, 'sci_name': 'Pica pica'},
            {"confidence": 0.8861, 'sci_name': 'Pica pica'}],
    }]

    for sample, expected in zip(test_files, results):
        file = ParseFileName(os.path.expanduser(sample))
        detections = run_analysis(file)
        assert (len(detections) == len(expected[model]))
        for det, this_det in zip(detections, expected[model]):
            assert (det.confidence == this_det['confidence'])
            assert (det.scientific_name == this_det['sci_name'])
    print('ok')
