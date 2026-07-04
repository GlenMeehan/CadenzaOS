# CadenzaOS Project Governance

## 1. Mission, Licensing, and Compliance
The CadenzaOS project develops a highly modular, open-source operating system under the **Apache License 2.0**. This license ensures a balance of commercial-friendly flexibility, collaborative engineering, and strict legal protection for both contributors and downstream users.

* **License:** All primary source code, build scripts (Zig build systems), and core architectural definitions are licensed under Apache 2.0.
* **Patent Grant:** By contributing, individuals and corporate entities automatically grant a perpetual, worldwide, non-exclusive, no-charge, royalty-free, irrevocable patent license for any patents necessarily infringed by their specific contribution.
* **Patent Retaliation:** If any entity initiates patent litigation against any participant alleging that CadenzaOS constitutes direct or contributory patent infringement, any patent licenses granted to that entity under Apache 2.0 for CadenzaOS shall terminate immediately as of the date such litigation is filed.
* **Copyright and NOTICE File:** The CadenzaOS project maintains a top-level `NOTICE` file alongside the `LICENSE` file. In compliance with Section 4(d) of the Apache License, any third-party attributions or modifications to foundational algorithms must be cleanly recorded here. 

---

## 2. Source Provenance and Inbound Licensing
To preserve the legal integrity of an operating system kernel, CadenzaOS enforces strict inbound code compliance to ensure no proprietary or GPL-tainted code enters the core tree.

* **Developer Certificate of Origin (DCO):** CadenzaOS uses the standard `Linux Foundation DCO (Version 1.1)`. Every contributor certifies that they have the legal right to submit their code under the project's license.
* **Commit Sign-Off:** Every commit must include a valid cryptographic or text sign-off line in the commit message:
    `Signed-off-by: Random Developer <random@developer.com>`
    Automated CI/CD hooks will reject Pull Requests containing unsigned or mismatching commits.
* **Third-Party Code / Copying:** Porting code (e.g., specific hardware storage drivers, filesystem formats, or standard library extensions) from projects using copyleft licenses (such as GPLv2 or GPLv3) into the core CadenzaOS codebase is strictly prohibited due to license incompatibility. Permissive code (MIT, BSD-3-Clause) may be accepted but must be isolated and documented in the `NOTICE` file.

---

## 3. Roles, Responsibilities, and Meritocracy
The project operates as a transparent meritocracy. Authority over the codebase and architectural direction is earned through sustained, high-quality technical contribution.

### 3.1 Contributor
Any individual who engages with the community via code submissions, documentation updates, issue tracking, bug triage, or architectural feedback.
* **Rights:** Eligible to open issues, submit Pull Requests, participate in architectural discussions, and review code.
* **Privileges:** Recognition in the project's contributor logs.

### 3.2 Maintainer
Contributors who have demonstrated deep technical competence, a strong understanding of the CadenzaOS architecture (e.g., its scheduling mechanics, memory map, and hardware layers), and alignment with the community's culture.
* **Privileges:** Write/Commit access to core repositories, ability to merge approved Pull Requests, and voting rights on technical implementations.
* **Responsibilities:**
    * Review PRs for technical soundness, styling guidelines, and license compliance.
    * Maintain the stability of the main branch.
    * Actively mentor new Contributors.
* **Lifecycle:**
    * *Nomination:* An active contributor may be nominated by any existing Maintainer after ~6 months of sustained engagement. Peer review and a simple majority consensus of current Maintainers are required for promotion.
    * *Emeritus Status:* Maintainers who become inactive for a period of 12 consecutive months will be gracefully transitioned to "Maintainer Emeritus" status, suspending active write privileges until regular contribution resumes.

### 3.3 Technical Steering Committee (TSC) / Project Lead
The overarching technical guidance of CadenzaOS is steered by its core maintainer group, chaired by the Project Lead.

* **Current Project Lead:** Glen Meehan
* **Responsibilities:**
    * Establish long-term roadmaps (e.g., moving from static registries to dynamic user-space separation, stable VFS layer specifications).
    * Serve as the final arbiter in deadlocked technical or architectural disputes.
    * Ensure the project consistently meets its licensing obligations.

---

## 4. Decision-Making Process
Whenever possible, the CadenzaOS project operates via **Lazy Consensus**.

* **Technical Changes (PRs):** Minor changes require a single Maintainer approval and a 48-hour window without objections before merging. Major architectural overhauls (e.g., restructuring memory management or rewriting the scheduler core) require explicit review and sign-off from at least two Maintainers or the Project Lead.
* **Formal Voting:** For administrative decisions, role promotions, or gridlocked technical disputes, a formal vote may be called by the TSC. Votes require a quorum of active Maintainers and pass on a simple majority (>50%). The Project Lead holds a tie-breaking vote.

---

## 5. Trademark and Branding Policy
To protect the identity of CadenzaOS and prevent user confusion regarding modified, unstable, or unofficial forks of the operating system:

* The names **CadenzaOS**, **Cadenza kernel**, and associated logo assets are protected project trademarks.
* Downstream distributors are free to modify and compile the source code under the Apache 2.0 license. However, if significant changes are made to the core behavior, security model, or default configurations, the resulting binary distribution must not be marketed as an "Official CadenzaOS Release" without explicit written permission from the Project Lead.
