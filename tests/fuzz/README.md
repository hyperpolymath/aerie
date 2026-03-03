# Fuzzing for aerie

This directory contains fuzzing configurations and targets for aerie components.

## Strategy

We use automated fuzzing to ensure that our network protocol parsers and core logic handle unexpected or malicious input gracefully.

## Running Fuzzers

Fuzzing is integrated into our quality assurance process. To run tests with fuzzing-like coverage:

```bash
just test
```
