# Architecture assets

- `oci-focus-private-finops.drawio` is the editable Draw.io source for the
  end-to-end private OCI FOCUS FinOps architecture.
- `oci-focus-private-finops.png` is the rendered image embedded in the project
  root README.

The solid components are deployed by the current Terraform and Ansible
projects. Oracle Analytics Cloud and its private access channel are shown with
a dashed border because they are planned for the next article and are not
created by the current Terraform modules.

Open the `.drawio` file with [diagrams.net](https://app.diagrams.net/) or the
Draw.io desktop application. When the source changes, regenerate the image at a
wide resolution so labels remain legible in GitHub's README renderer.
