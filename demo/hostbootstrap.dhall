-- The hostbootstrap-demo static-base config (read pre-binary by the Python
-- bootstrapper to learn the project name it builds and execs). The resource
-- budget is the demo's one ceiling: 6 cores, 10 GiB memory, 40 GiB storage.
{ project = "hostbootstrap-demo"
, dockerfile = "docker/Dockerfile"
, resources = { cpu = 6, memory = "10GiB", storage = "40GiB" }
}
