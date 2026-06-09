-- A canonical static-base hostbootstrap.dhall instance, used as a decode fixture.
{ project = "demo"
, dockerfile = "docker/demo.Dockerfile"
, resources = { cpu = 4, memory = "8GiB", storage = "20GiB" }
}
