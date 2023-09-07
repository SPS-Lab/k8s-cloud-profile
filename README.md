# k8s-cloud-profile

This is a profile for CloudLab based on the K8S profile that does the following:

* 5 CPU nodes with ARM processors and Ubuntu 22.04 by default
* Installs kube-spray based on release version number (current: v2.22.1)
* Installs Longhorn and Volcano for IO and MPI applications
* Performs modifications to run perf (changes into perf_event_paranoid and kptr_restrict)
