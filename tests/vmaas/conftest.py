from __future__ import annotations

import os
from uuid import uuid4

import pytest

from tests.core.grpc_client import GRPCClient
from tests.core.helpers import (
    wait_for_subnet_cr,
    wait_for_subnet_deletion,
    wait_for_subnet_ready,
    wait_for_virtual_network_cr,
    wait_for_virtual_network_deletion,
    wait_for_virtual_network_ready,
)
from tests.core.k8s_client import K8sClient
from tests.core.runner import env, poll_until


@pytest.fixture(scope="session")
def k8s_virt_client(namespace: str) -> K8sClient:
    vm_kubeconfig: str = os.environ["OSAC_VM_KUBECONFIG"]
    return K8sClient(namespace=namespace, kubeconfig=vm_kubeconfig)


@pytest.fixture(scope="session")
def vm_template() -> str:
    return env("OSAC_VM_TEMPLATE", "osac.templates.ocp_virt_vm")


@pytest.fixture(scope="session")
def network_class() -> str:
    return env("OSAC_NETWORK_CLASS", "cudn_net")


@pytest.fixture(scope="session")
def compute_instance_subnet(grpc: GRPCClient, k8s_hub_client: K8sClient, network_class: str) -> str:
    """Subnet UUID for ComputeInstance create.

    If OSAC_COMPUTE_INSTANCE_SUBNET is set, that subnet is used. Otherwise a session-scoped
    VirtualNetwork + Subnet is created and torn down after tests.
    """
    explicit: str = os.environ.get("OSAC_COMPUTE_INSTANCE_SUBNET", "").strip()
    if explicit:
        yield explicit
        return

    tag: str = uuid4().hex[:8]
    second_octet: int = 200 + (uuid4().int % 55)
    vn_cidr: str = f"10.{second_octet}.0.0/16"
    subnet_cidr: str = f"10.{second_octet}.1.0/24"

    vn_name: str = f"e2e-ci-vnet-{tag}"
    vn_id: str = grpc.create_virtual_network(name=vn_name, network_class=network_class, ipv4_cidr=vn_cidr)
    vn_cr_name: str = wait_for_virtual_network_cr(k8s=k8s_hub_client, uuid=vn_id)
    try:
        wait_for_virtual_network_ready(k8s=k8s_hub_client, name=vn_cr_name, retries=180)
    except TimeoutError as exc:
        msg = (
            "compute_instance_subnet: VirtualNetwork never became Ready. Set OSAC_COMPUTE_INSTANCE_SUBNET "
            f"to an existing subnet UUID, or inspect VirtualNetwork {vn_cr_name!r} (phase stuck in "
            "Progressing usually indicates cluster or user-defined-network issues)."
        )
        raise RuntimeError(msg) from exc

    subnet_name: str = f"e2e-ci-subnet-{tag}"
    subnet_id: str = grpc.create_subnet(name=subnet_name, virtual_network=vn_id, ipv4_cidr=subnet_cidr)
    subnet_cr_name: str = wait_for_subnet_cr(k8s=k8s_hub_client, uuid=subnet_id)
    try:
        wait_for_subnet_ready(k8s=k8s_hub_client, name=subnet_cr_name, retries=180)
    except TimeoutError as exc:
        msg = (
            "compute_instance_subnet: Subnet never became Ready. Set OSAC_COMPUTE_INSTANCE_SUBNET "
            f"or inspect Subnet CR {subnet_cr_name!r}."
        )
        raise RuntimeError(msg) from exc

    try:
        yield subnet_id
    finally:
        grpc.delete_subnet(subnet_id=subnet_id)
        wait_for_subnet_deletion(k8s=k8s_hub_client, name=subnet_cr_name)
        poll_until(
            fn=lambda: subnet_id not in grpc.list_subnet_ids(),
            until=lambda v: v is True,
            retries=30,
            delay=5,
            description=f"Subnet {subnet_id} removal from API",
        )

        grpc.delete_virtual_network(vn_id=vn_id)
        wait_for_virtual_network_deletion(k8s=k8s_hub_client, name=vn_cr_name)
        poll_until(
            fn=lambda: vn_id not in grpc.list_virtual_network_ids(),
            until=lambda v: v is True,
            retries=30,
            delay=5,
            description=f"VirtualNetwork {vn_id} removal from API",
        )
