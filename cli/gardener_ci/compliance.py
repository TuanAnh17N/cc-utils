'''
a collection of hopefully useful tools for compliance-related, half-automated tasks

since some commands will require many (and lengthy) arguments, which, in many cases, will
rarely change, callers may optionally specify a "defaults file" (which is expected to be a YAML
document containing default-values using CLI-arg-names).

Example defaults-file contents:

```
left_name: github.com/example/example
left_version: 1.2.3
right_name: github.com/example/example
right_version: 2.0.0
ocm_repo_urls:
 - eu.gcr.io/example/example-repo
```
'''

import dataclasses
import re

import dacite
import yaml

import ci.util
import ccc.oci
import cnudie.iter
import cnudie.retrieve
import ctx
import ocm
import ocm.util
import reutil


_cfg = ctx.cfg


@dataclasses.dataclass
class ComponentResourceNames:
    component_name: str
    resource_name: str


@dataclasses.dataclass
class DiffArguments:
    left_name: str
    right_name: str
    left_version: str
    right_version: str
    outfile_prefix: str
    ocm_repo_urls: list[str]
    exclude_component_names: list[str] = None
    exclude_component_resource_names: list[ComponentResourceNames] = None
    resource_types: list[str] = None
    name_template: str = None
    name_template_expr: str = None


def diff(
    left_name: str=None,
    right_name: str=None,
    left_version: str=None,
    right_version: str=None,
    name_template: str=None,
    name_template_expr: str=None,
    resource_types: [str]=None,
    ocm_repo_urls: [str]=None,
    cache_dir: str=_cfg.ctx.cache_dir,
    defaults_file: str=None,
    outfile_prefix: str='resource-diff'
):
    if defaults_file:
        params = ci.util.parse_yaml_file(defaults_file)
    else:
        params = {}

    if left_name:
        params['left_name'] = left_name
    if right_name:
        params['right_name'] = right_name
    if left_version:
        params['left_version'] = left_version
    if right_version:
        params['right_version'] = right_version
    if ocm_repo_urls:
        params['ocm_repo_urls'] = ocm_repo_urls
    if name_template:
        params['name_template'] = name_template
    if name_template_expr:
        params['name_template_expr'] = name_template
    if resource_types:
        params['resource_types'] = resource_types
    if outfile_prefix:
        params['outfile_prefix'] = outfile_prefix

    try:
        parsed = dacite.from_dict(
            data_class=DiffArguments,
            data=params,
        )
    except:
        print('missing arguments (check either CLI or defaults_file)')
        raise

    if parsed.name_template and parsed.name_template_expr:
        raise ValueError('at most one of name_template_expr, name_template must be specified')

    print('retrieving component-descriptors (might take a few seconds)')

    component_descriptor_lookup = cnudie.retrieve.create_default_component_descriptor_lookup(
        ocm_repository_lookup=cnudie.retrieve.ocm_repository_lookup(
            *parsed.ocm_repo_urls,
        ),
        oci_client=ccc.oci.oci_client(),
        cache_dir=cache_dir,
    )

    def _components(
        component_descriptor: ocm.ComponentDescriptor,
    ):
        if parsed.exclude_component_names:
            component_filter = reutil.re_filter(
                include_regexes=(),
                exclude_regexes=parsed.exclude_component_names,
                value_transformation=lambda comp: comp.name
            )
        else:
            component_filter = None

        return tuple(
            component_node.component for component_node in cnudie.iter.iter(
                component=component_descriptor.component,
                lookup=component_descriptor_lookup,
                node_filter=cnudie.iter.Filter.components,
            ) if not component_filter or component_filter(component_node.component)
        )

    left_cd = component_descriptor_lookup(ocm.ComponentIdentity(
        name=parsed.left_name,
        version=parsed.left_version,
    ))
    left_components = _components(
        component_descriptor=left_cd,
    )

    right_cd = component_descriptor_lookup(ocm.ComponentIdentity(
        name=parsed.right_name,
        version=parsed.right_version,
    ))
    right_components = _components(
        component_descriptor=right_cd,
    )

    def resource_version_id(component, resource):
        # ignore component-version, honour resource-version
        return component.name, resource.name, resource.version

    def iter_resources_with_ids(components):
        for c in components:
            for r in c.resources:
                if parsed.resource_types:
                    if isinstance(r.type, ocm.ArtefactType):
                        resource_type = r.type.value
                    else:
                        resource_type = r.type

                    if not resource_type in parsed.resource_types:
                        continue

                if parsed.exclude_component_resource_names:
                    skip = True
                    for component_resource_name in parsed.exclude_component_resource_names:
                        if re.fullmatch(component_resource_name.component_name, c.name) \
                            and \
                            re.fullmatch(component_resource_name.resource_name, r.name):
                            break
                    else:
                        skip = False

                    if skip:
                        continue

                yield c, r, resource_version_id(c, r)

    left_resource_version_ids = {
        cri[2] for cri in iter_resources_with_ids(left_components)
    }
    right_resource_version_ids = {
        cri[2] for cri in iter_resources_with_ids(right_components)
    }

    new_resource_version_ids = [
        (c,r,i) for c,r,i in iter_resources_with_ids(right_components)
        if not i in left_resource_version_ids
    ]
    removed_resource_version_ids = [
        (c,r,i) for c,r,i in iter_resources_with_ids(left_components)
        if not i in right_resource_version_ids
    ]

    def resource_as_dict(component, resource, resource_id):
        if (main_src := ocm.util.main_source(component, no_source_ok=True)):
            src_url = main_src.access.repoUrl
        elif isinstance(resource.access, ocm.OciAccess):
            src_url = resource.access.imageReference
        else:
            src_url = '<unknown>'

        if isinstance(resource.access, ocm.OciAccess):
            if orig_label := resource.find_label(
                'cloud.gardener.cnudie/migration/original_ref'
            ):
                img_ref = orig_label.value
            else:
                img_ref = resource.access.imageReference

            pull_cmd = {'pull_cmd': f'docker pull {img_ref}'}
        else:
            pull_cmd = {}

        if parsed.name_template:
            name = parsed.name_template.format(
                resource=resource,
                component=component,
            )
        elif parsed.name_template_expr:
            name = eval(parsed.name_template_expr) # nosec B307
        else:
            name = resource.name

        return {
            'name': name,
            'version': resource.version,
            'src_url': src_url,
            **pull_cmd,
        }

    print(f'{left_cd.component.name}:{left_cd.component.version} -> {right_cd.component.version}')
    print(20 * '=')

    print(f'found {len(new_resource_version_ids)=}')
    print('listing new resource-versions')
    print()

    print(yaml.safe_dump((new_resources := [
        resource_as_dict(c,r,i) for c,r,i in new_resource_version_ids
    ])))

    print()
    print()

    print(f'found {len(removed_resource_version_ids)=}')
    print('listing removed resource-versions')
    print()

    print(yaml.safe_dump((removed_resources := [
        resource_as_dict(c,r,i) for c,r,i in removed_resource_version_ids
    ])))

    outfile_new = f'{parsed.outfile_prefix}-added.yaml'
    outfile_removed = f'{parsed.outfile_prefix}-removed.yaml'

    print()

    with open(outfile_new, 'w') as f:
        print(f'writing added resource-versions to {outfile_new=}')
        yaml.safe_dump(
            new_resources,
            f,
        )
        print()

    with open(outfile_removed, 'w') as f:
        print(f'writing removed resource-versions to {outfile_removed=}')
        yaml.safe_dump(
            removed_resources,
            f,
        )
