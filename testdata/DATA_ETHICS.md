# Ethics of the Data Collection Process

The data in this artifact were produced by controlled experiments on isolated BSC test networks.
The collection process did not involve human subjects, user surveys, interviews, human-subject
observations, personal data, or private user activity. Consequently, the artifact contains no
consent records or personally identifiable information.

The local Attack 1, Attack 2, and repair experiments used test validator accounts and test keys
in an isolated Linux or Docker environment. The delivery experiment used dedicated geo-distributed test hosts
and test validator keys. The experiments were not intended to connect to or modify production BSC
validators or production blockchain infrastructure. The scripts and deployment configuration must
be used only with infrastructure that the operator is authorized to control.

The paper's validator-set-change analysis also uses aggregate observations from the public BSCScan
validator-set page. The analysis records weekly counts of validator-set changes; it does not collect
personal information or attempt to identify individual people behind validator entities.

SSH private keys, cloud credentials, and other access secrets are deployment credentials rather
than research data. They must remain outside the public artifact repository and must not be
included in the dataset archives.

The artifact can modify or delete testnet state, consume cloud resources, and generate network
traffic between the experiment hosts. These risks are operational rather than human-subject risks;
evaluators should use dedicated test resources, test keys, and authorized cloud accounts, and they
should stop or terminate cloud instances after the experiment.

This statement describes the data collection represented in the artifact. The authors should
confirm separately whether their institution requires any formal ethics or exemption determination
for the overall research project.
