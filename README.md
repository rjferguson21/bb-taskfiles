# BigBang Development Taskfiles

Task automation for [BigBang](https://repo1.dso.mil/big-bang/bigbang) development workflows. Provides tasks for creating k3d clusters, deploying BigBang, and running tests on EC2 instances or locally.

## Requirements

- [go-task](https://taskfile.dev/)
- [helm](https://helm.sh/)
- [yq](https://github.com/mikefarah/yq)
- [k3d](https://k3d.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- AWS CLI (for remote development)

## Quick Start

```bash
# List available tasks
task --list

# Full workflow: EC2 instance → k3d cluster → BigBang → tests
task

# Local development: k3d cluster → BigBang → tests
task localdev
```

## Usage

### Remote Development (EC2)

The default task creates an EC2 instance, provisions a k3d cluster on it, deploys BigBang, and runs tests:

```bash
task
```

Manage EC2 instances:

```bash
task aws:ec2          # Create EC2 instance
task aws:ec2:destroy  # Destroy EC2 instance
```

### Local Development

Run everything locally without EC2:

```bash
task localdev
```

### Package Development

For developing individual BigBang packages, copy `package.yml` to your package repo and run:

```bash
task -t package.yml              # Create cluster, deploy BigBang with local package, test
task -t package.yml test:unit    # Run unit tests only
task -t package.yml test:e2e     # Run E2E tests only
```

### Individual Tasks

```bash
task k3d:create      # Create k3d cluster with Flux and MetalLB
task deploy          # Deploy BigBang to cluster
task test            # Run Helm tests
task schema-validate # Validate BigBang package schemas
```

## Configuration

Set Registry1 credentials as environment variables:

```bash
export REGISTRY1_USERNAME=<username>
export REGISTRY1_PASSWORD=<password>
```

For EC2 development, a `dev.yaml` file is created with instance metadata after running `task aws:ec2`.

## Project Structure

```
├── Taskfile.yml          # Main taskfile (cluster creation, deployment, testing)
├── package.yml           # Package development taskfile
└── taskfiles/
    └── aws.yml           # EC2 instance management
```
