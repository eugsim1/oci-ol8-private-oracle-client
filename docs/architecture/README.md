# Architecture assets

- `oci-focus-private-finops.drawio` and its rendered PNG show the physical OCI
  deployment topology and network boundaries.
- `oci-focus-private-finops-sda.drawio` and its rendered PNG show the Solution
  Design Architecture (SDA): logical layers, responsibilities, data flow, and
  cross-cutting security controls.
- `generate-diagrams.ps1` regenerates both editable Draw.io files from Oracle's
  official OCI Draw.io stencil library.

The solid components are deployed by the current Terraform and Ansible
projects. Oracle Analytics Cloud and its private access channel are shown with
a dashed border because they are planned for the next article and are not
created by the current Terraform modules.

The diagrams use Oracle service stencils from the official
[OCI Architecture Diagram Toolkit](https://docs.oracle.com/en-us/iaas/Content/General/Reference/graphicsfordiagrams.htm)
and follow the recommended Region, VCN, subnet, and workload hierarchy. Generic
boxes are used only for external actors, project-specific software, and logical
responsibilities that do not map to an OCI service icon.

## Regenerate the editable sources

Download and extract the Draw.io toolkit, then run from the project root:

```powershell
.\docs\architecture\generate-diagrams.ps1 `
  -OciLibraryPath 'C:\path\to\OCI Library.xml'
```

The generated `.drawio` files are self-contained: the selected OCI stencil
geometry is embedded in each file. The toolkit is needed only to regenerate
the sources, not to open or edit them.

Open each `.drawio` file with [diagrams.net](https://app.diagrams.net/) or the
Draw.io desktop application and export it to the matching PNG filename. Use a
wide page so labels remain legible in GitHub's README renderer.
