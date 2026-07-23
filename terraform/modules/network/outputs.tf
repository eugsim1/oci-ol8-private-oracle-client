output "vcn_id" { value = oci_core_vcn.this.id }
output "private_subnet_id" { value = oci_core_subnet.private.id }
output "vcn_cidr" { value = var.vcn_cidr }
output "nat_gateway_id" { value = oci_core_nat_gateway.this.id }
output "service_gateway_id" { value = oci_core_service_gateway.this.id }
output "private_route_table_id" { value = oci_core_route_table.private.id }
output "private_security_list_id" { value = oci_core_security_list.private.id }
output "resource_compartment_ids" {
  value = distinct([
    oci_core_vcn.this.compartment_id,
    oci_core_nat_gateway.this.compartment_id,
    oci_core_service_gateway.this.compartment_id,
    oci_core_route_table.private.compartment_id,
    oci_core_security_list.private.compartment_id,
    oci_core_subnet.private.compartment_id
  ])
}
