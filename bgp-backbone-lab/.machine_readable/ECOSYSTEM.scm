;; SPDX-License-Identifier: PMPL-1.0-or-later
(ecosystem (metadata (version "0.2.0") (last-updated "2026-02-08"))
  (project (name "bgp-backbone-lab") (purpose "eBGP backbone simulation with containerlab") (role network-lab))
  (flatracoon-integration
    (parent "flatracoon/netstack")
    (layer network)
    (depended-on-by ())
    (depends-on ())))
