---
layout: appnote
title: "Hardware Entropy: Avalanche-Breakdown RNG Without Post-Processing"
author: Tyler Graff
date: 2026-07-01
---

This note describes the design of a hardware true random number generator I built for a low-power security device. The generator uses avalanche noise produced by a zener diode, digitized by a successive-approximation ADC, and conditioned by an extended Von Neumann extractor that preserves min-entropy without deterministic post-processing. The output feeds a one-time pad system for a hardware VPN.

## The Problem

Cryptographic systems need entropy. Software PRNGs, even when cryptographically secure, are deterministic. Their security depends on seed secrecy. A failure in the underlying entropy source can be masked indefinitely by the PRNG's diffusion properties. This is unacceptable for a hardware VPN whose security model rests on one-time pad (information-theoretic security). A compromised PRNG looks identical to a healthy one from its output alone. A compromised TRNG does not, if you measure correctly.

The design goals:

- Generate full-entropy (IID) output from a physical noise source
- No deterministic conditioning (no whitening via PRNG)
- Graceful and visible degradation under fault and failure conditions (reduced throughput, never compromised output)
- Low-power, embeddable in a microcontroller-based system running on 5v
- Sufficient throughput to fill a 4 GB SD card with one-time pad overnight

## The Noise Source: Avalanche Breakdown in a Zener Diode

Avalanche breakdown in a reverse-biased zener diode produces broadband shot noise from impact ionization: charge carriers in the depletion region gain sufficient energy from the electric field to free additional carriers through collisions, creating a self-sustaining cascade. The resulting current fluctuations are fundamentally rooted in non-deterministic quantum tunneling and scattering processes and exhibit an even power spectral density limited by junction properties.

Noise amplitude and spectrum depend on the breakdown voltage, bias current, and manufacturing variation. I tested many units with breakdown voltages ranging from 12v to 24v. The 18v devices produced the most consistent and highest-amplitude noise across dozens of samples. Noise-to-DC ratio was maximized by biasing the diode at low current near the knee of its I-V curve. Oscilloscope FFT measurements confirmed a flat noise power spectrum well in excess of twice the ADC sample rate, ensuring that consecutive samples are not correlated by bandwidth limitation.

The challenge is that the system runs on 5v. Biasing an 18v zener requires a higher supply rail.

## Power Supply: Fixed Duty Cycle Boost Converter

An asynchronous boost converter charges a storage capacitor to 25v from the 5v system rail. The boost topology is implemented directly in the microcontroller firmware: a GPIO drives a logic-level MOSFET switching the inductor to charge a storage capacitor.

The system operates in a three-phase cycle:

1. **Charge:** The boost converter runs until the storage capacitor reaches 25v.
2. **Settle:** The converter stops and a quiescent period eliminates residual LC ringing on the 25v rail.
3. **Collect:** ADC sampling for a fixed collection interval. Avalanche noise from the biased zener passes through an AC-coupled op-amp gain stage that amplifies the noise signal and scales it to the ADC's 0-5v input range.

The storage capacitor is sized so that bias-point droop during the collection phase is minimal. Collection duty cycle is approximately 90%, with the remaining 10% consumed by the boost charge and settle phases.

The op-amp's noise contribution was characterized in-situ by measuring output jitter at mid-range while running an active VPN session. The result was ±1 LSB measurement floor. The LSB is accordingly excluded from entropy collection.

The entire cycle is open-loop and time-based to eliminate the complexity and associated failure modes that closed-loop control would introduce in a security-critical path.

## Digitization: SAR ADC via SPI and DMA

The ADC is a 10-bit successive-approximation register device, clocked in the low MSPS range, connected to the microcontroller via SPI with DMA transfer for sample collection without CPU intervention. The TRNG analog section is physically located as far from both microcontrollers as PCB geometry allows, protected by a continuous ground plane on the bottom layer and a grounded guard ring on the top layer. In-situ op-amp noise measurement confirms that digital switching noise does not meaningfully couple into the analog signal path.

### SAR Artifacts: DNL Errors and Comparator Metastability

Significant investigation went into characterizing non-ideal ADC behavior. The primary artifact stems from differential nonlinearity (DNL) errors in the ADC's internal comparator voltage reference ladder.

The failure mode: when the true analog input falls within a comparator's metastable region (the uncertainty band around a reference level) there is an elevated probability of an incorrect binary decision. When the comparator errs on an early bit (MSB side), the SAR algorithm's convergence becomes pathological. Depending on the polarity of the initial error, the remaining bits all resolve to 0 or 1 as the algorithm attempts to converge on a code that has irrecoverably diverged from the true value. This produces statistically significant runs of identical bits in the LSB positions of converted 10-bit values:

```
0110100000    (pathological tail of five 0s)
1001111111    (pathological tail of six 1s)
```

These artifacts are subtle. They pass simple statistical tests (mean, variance, monobit frequency) but manifest as conditional bias: dependence between bit positions within a single conversion, which is precisely the kind of non-independence that destroys per-sample min-entropy.

## Entropy Extraction: Extended Von Neumann Debiaser

The general principle below (mapping equiprobable input symbols to output codes) was formalized by Peter Elias in [*The Efficient Construction of an Unbiased Random Sequence*](https://projecteuclid.org/journals/annals-of-mathematical-statistics/volume-43/issue-3/The-Efficient-Construction-of-an-Unbiased-Random-Sequence/10.1214/aoms/1177692552.pdf) (1972). The implementation described here is an independent rediscovery, extended to exploit specific knowledge of SAR convergence failure.

The classic Von Neumann debiaser examines pairs of bits:
```
01 → output 0
10 → output 1
00 and 11 → discard
```
It produces unbiased output from a source with unknown but fixed bias, at the cost of throughput. But it only corrects first-order bias and cannot address the intra-sample correlation produced by SAR DNL errors.

The implementation targets the failure mechanism directly rather than relying on statistical characterization from a calibration corpus. From each 10-bit sample:

1. **Discard the LSB**, dominated by op-amp noise floor (±1 LSB, measured in-situ).
2. **Discard the MSB**, affected by gain-stage range scaling imperfections.
3. **Examine the interior 8 bits for monotonic tails.** If the sample terminates in a run of identical bits (the signature of SAR convergence failure from comparator metastability), the run is truncated. The remaining prefix bits, resolved before the pathological convergence, are retained as valid entropy.
4. **Output the retained bits.** $k$ usable prefix bits contribute $k$ bits of output. Samples with longer monotonic tails contribute fewer bits, and vice versa.

This approach is more robust than building a static lookup table from a calibration corpus because it filters on the *cause* (monotonic runs from comparator metastability) rather than the *symptom* (non-uniform sequence probabilities). The method does not depend on individual device characteristics and does not go stale as the DNL profile drifts with temperature or aging.

## Online Health Testing and Graceful Degradation

Output entropy is accumulated into blocks of approximately 1 KB. Each block undergoes several bit- and byte-level statistical health tests. If any test indicates deviation beyond the significance threshold ($\alpha = 0.05$), the entire block is discarded.

This produces the key system property: **graceful degradation under fault**. An operator monitoring the device sees reduced production rate as the first sign of hardware degradation. As the noise source degrades, more samples exhibit longer monotonic tails, and throughput drops accordingly. If it fails entirely, output ceases. *Contrast this with deterministic PRNG conditioning where a dead noise source still produces full-rate but deterministic output.* The system is designed so that failure looks like failure.

The combined system produced output that passed the full Diehard statistical test battery across 10 engineering samples without deterministic post-processing, at 0°C, 25°C, and 45°C ambient. The entropy is white at the point of extraction, not whitened after the fact.

## Application: One-Time Pad for Hardware VPN

The entropy feeds a one-time pad (OTP) VPN system. Two SD cards are inserted into a single VPN device and filled with identical key material at approximately 1Mbps. One card is then physically transported (key distribution via sneakernet) to a second device. The paired devices can then communicate with information-theoretic security, the only encryption scheme whose security does not rest on computational hardness assumptions.

The VPN hardware itself uses two Harvard-architecture microcontrollers: one managing the LAN interface, the other managing the WAN interface. The Harvard architecture (separate instruction and data memory buses) of each processor, combined with the physical separation between the two, prevents remote code execution by construction. There is no electrical path from the WAN-facing processor to the LAN-facing processor's instruction memory. This provides a hardware-enforced security boundary that does not depend on software correctness. Combined with OTP encryption, the device offers security guarantees grounded in physics and hardware topology rather than algorithmic assumptions.

## What I'd Do Differently

**Faster ADC.** Spectral bandwidth from the noise source is abundant. The harder problems are op-amp noise floor and EMI coupling, both of which are amplitude-domain problems. A faster ADC increases throughput without requiring difficult improvements to the analog front end.

**Characterize more diode units.** Ten units per voltage is enough to identify a good operating point, but not enough for statistical confidence in manufacturing consistency. A production device should characterize far more units and, critically, establish acceptance criteria for incoming inspection.

**Adaptive bias voltage.** The boost converter output is fixed at 25v, but the optimal zener bias point that maximizes noise amplitude varies with temperature and aging. An improved system could use the per-block health test results as a feedback signal: if block rejection rate rises, dither the boost target voltage in small increments to find an operating point that minimizes failing blocks. This closes the loop between the statistical output and the analog operating point without introducing complexity into the entropy path itself.

