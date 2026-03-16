#!/usr/bin/env bash
# SPDX-License-Identifier: PMPL-1.0-or-later

function isort_all () {
    isort -y hyperglass/*.py
    if [[ ! $? == 0 ]]; then
      exit 1
    fi
    isort -y hyperglass/**/*.py
    if [[ ! $? == 0 ]]; then
      exit 1
    fi
}

function validate_examples () {
  python3 ./validate_examples.py
  if [[ ! $? == 0 ]]; then 
    exit 1
  fi
}

# isort_all
validate_examples

exit 0