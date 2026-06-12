-- The hostbootstrap-demo static-base config (read pre-binary by the Python
-- bootstrapper to learn the project name it builds and execs). The resource
-- budget is the demo's one ceiling: 6 cores, 10 GiB memory, 80 GiB storage.
-- Storage is 80 GiB because the in-VM `test all` holds the ~20 GB project image
-- (build #3) AND its `kind load` duplicate inside the kind node, plus the base
-- and the host-native build store — more than 40 GiB.
{ project = "hostbootstrap-demo"
, dockerfile = "docker/Dockerfile"
, resources = { cpu = 6, memory = "10GiB", storage = "80GiB" }
}
