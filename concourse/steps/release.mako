<%def
  name="release_step(job_step, job_variant, github_cfg, indent)",
  filter="indent_func(indent),trim"
>
<%
import os

from makoutil import indent_func
from concourse.steps import step_lib
import ci.util
import concourse.steps.component_descriptor_util as cdu
import concourse.model.traits.version
import concourse.model.traits.release
import ocm
import version
ReleaseCommitPublishingPolicy = concourse.model.traits.release.ReleaseCommitPublishingPolicy
ReleaseNotesPolicy = concourse.model.traits.release.ReleaseNotesPolicy
VersionInterface = concourse.model.traits.version.VersionInterface
BuildstepLogAsset = concourse.model.traits.release.BuildstepLogAsset
BuildstepFileAsset = concourse.model.traits.release.BuildstepFileAsset
FileAssetMode = concourse.model.traits.release.FileAssetMode
version_file = job_step.input('version_path') + '/version'
release_trait = job_variant.trait('release')

if (release_commit_callback_image_reference := release_trait.release_callback_image_reference()):
  release_commit_callback_image_reference = release_commit_callback_image_reference.image_reference()

version_trait = job_variant.trait('version')
version_interface = version_trait.version_interface()
version_operation = release_trait.nextversion()
release_commit_message_prefix = release_trait.release_commit_message_prefix()
next_cycle_commit_message_prefix = release_trait.next_cycle_commit_message_prefix()

if job_variant.has_trait('publish'):
  publish_trait = job_variant.trait('publish')
  helmcharts = publish_trait.helmcharts
else:
  helmcharts = ()

has_slack_trait = job_variant.has_trait('slack')
if has_slack_trait:
  slack_trait = job_variant.trait('slack')
  slack_channel_cfgs = [cfg.raw for cfg in slack_trait.channel_cfgs()]

github_release_tag = release_trait.github_release_tag()
git_tags = release_trait.git_tags()

repo = job_variant.main_repository()

component_descriptor_path = os.path.join(
  job_step.input('component_descriptor_dir'),
  cdu.component_descriptor_fname(ocm.SchemaVersion.V2),
)

component_descriptor_trait = job_variant.trait('component_descriptor')
ocm_repository_mappings = component_descriptor_trait.ocm_repository_mappings()

release_callback_path = release_trait.release_callback_path()
next_version_callback_path = release_trait.next_version_callback_path()
post_release_callback_path = release_trait.post_release_callback_path()

release_notes_policy = release_trait.release_notes_policy()
if release_notes_policy is ReleaseNotesPolicy.DEFAULT:
  process_release_notes = True
elif release_notes_policy is ReleaseNotesPolicy.DISABLED:
  process_release_notes = False
else:
  raise ValueError(release_notes_policy)

release_commit_publishing_policy = release_trait.release_commit_publishing_policy()
if release_commit_publishing_policy is ReleaseCommitPublishingPolicy.TAG_ONLY:
  merge_back = False
  push_release_commit = False
  create_release_commit = True
  bump_commit = True
elif release_commit_publishing_policy is ReleaseCommitPublishingPolicy.TAG_AND_PUSH_TO_BRANCH:
  merge_back = False
  push_release_commit = True
  create_release_commit = True
  bump_commit = True
elif release_commit_publishing_policy is ReleaseCommitPublishingPolicy.TAG_AND_MERGE_BACK:
  push_release_commit = False
  merge_back = True
  create_release_commit = True
  bump_commit = True
elif release_commit_publishing_policy is ReleaseCommitPublishingPolicy.SKIP:
  push_release_commit = False
  merge_back = False
  create_release_commit = False
  bump_commit = False
else:
  raise ValueError(release_commit_publishing_policy)

mergeback_commit_msg_prefix = release_trait.merge_release_to_default_branch_commit_message_prefix()

assets = release_trait.assets

def github_asset_name(asset):
  if asset.github_asset_name:
    return asset.github_asset_name

  return '-'.join(
    [asset.name] + list(asset.artefact_extra_id.values())
  )
%>
import glob
import hashlib
import os
import tarfile
import tempfile
import zlib

import ccc.concourse
import ccc.github
import ccc.oci
import ci.util
import cnudie.iter
import cnudie.retrieve
import cnudie.util
import cnudie.validate
import concourse.steps.component_descriptor_util as cdu
import concourse.steps.release
import concourse.model.traits.version
import concourse.model.traits.release
import concourse.util
import ocm
import ocm.upload
import ocm.util
import release_notes.ocm
import github.release
import github.util
import gitutil

import git
import magic

import traceback

${step_lib('release')}

VersionInterface = concourse.model.traits.version.VersionInterface

with open('${version_file}') as f:
  version_str = f.read()

repo_dir = ci.util.existing_dir('${repo.resource_name()}')
repository_branch = '${repo.branch()}'

github_cfg = ccc.github.github_cfg_for_repo_url(
  ci.util.urljoin(
    '${repo.repo_hostname()}',
    '${repo.repo_path()}',
  )
)
github_api = ccc.github.github_api(github_cfg)
repo_owner = '${repo.repo_owner()}'
repo_name = '${repo.repo_name()}'

<%
import concourse.steps
template = concourse.steps.step_template('component_descriptor')
ocm_repository_lookup = template.get_def('ocm_repository_lookup').render
%>
${ocm_repository_lookup(ocm_repository_mappings)}

oci_client = ccc.oci.oci_client()
component_descriptor_lookup = cnudie.retrieve.create_default_component_descriptor_lookup(
  ocm_repository_lookup=ocm_repository_lookup,
  oci_client=oci_client,
)
version_lookup = cnudie.retrieve.version_lookup(
  ocm_repository_lookup=ocm_repository_lookup,
  oci_client=oci_client,
)

component_descriptor = cdu.component_descriptor_from_dir(
  '${job_step.input('component_descriptor_dir')}'
)
component = component_descriptor.component

% if helmcharts:
component_descriptor_target_ref = cnudie.util.target_oci_ref(component=component)
## if there are helmcharts, we need to preprocess component-descriptor in order to include
## mappings emitted from helmcharts-step
% for helmchart in helmcharts:
mappingfile_path = 'helmcharts/${helmchart.name}.mapping.json'
logger.info(f'adding helmchart-mapping from {mappingfile_path=}')
## mappingfiles are typically small, so don't bother streaming
with open(mappingfile_path, 'rb') as f:
  mapping_bytes = f.read()

mapping_leng = len(mapping_bytes)
mapping_digest = f'sha256:{hashlib.sha256(mapping_bytes).hexdigest()}'

oci_client.put_blob(
  image_reference=component_descriptor_target_ref,
  digest=mapping_digest,
  octets_count=mapping_leng,
  data=mapping_bytes,
)

component.resources.append(
  ocm.Resource(
    name='${helmchart.name}',
    version=version_str,
    type='helmchart-imagemap',
    extraIdentity={
      'type': 'helmchart-imagemap',
    },
    access=ocm.LocalBlobAccess(
      mediaType='application/data',
      localReference=mapping_digest,
      size=mapping_leng,
    ),
  )
)
% endfor
% endif

oci_client = ccc.oci.oci_client()
% if assets:
component_descriptor_target_ref = cnudie.util.target_oci_ref(component=component)
concourse_client = ccc.concourse.client_from_env()
current_build = concourse.util.find_own_running_build()
build_plan = current_build.plan()

## keep redundant copies of asset-files in order to also upload them as github-release-assets later
## each entry has the following attributes:
## - fh # either filelike-object or path to a file; filelike-objects are reset to first byte to read
## - name # github-asset-name
## - mimetype
## assuming buildlogs are typically not of interest for gh-releases, hardcode to omit those
github_assets = []

main_source = ocm.util.main_source(component)
main_source_ref = {
  'name': main_source.name,
  'version': main_source.version,
}
% for asset in assets:
% if isinstance(asset, BuildstepLogAsset):
task_id = build_plan.task_id(task_name='${asset.step_name}')
build_events = concourse_client.build_events(build_id=current_build.id())
leng = 0
hash = hashlib.sha256()
compressor = zlib.compressobj(wbits=31) # 31: be compatible to gzip
with tempfile.TemporaryFile() as f:
  for line in build_events.iter_buildlog(task_id=task_id):
    line = line.encode('utf-8')
    buf = compressor.compress(line)
    leng += len(buf)
    hash.update(buf)
    f.write(buf)
  buf = compressor.flush()
  leng += len(buf)
  hash.update(buf)
  f.write(buf)

  f.seek(0)
  logger.info(f'pushing blob for asset ${asset.name} to {component_descriptor_target_ref}')
  digest = f'sha256:{hash.hexdigest()}'
  oci_client.put_blob(
    image_reference=component_descriptor_target_ref,
    digest=digest,
    octets_count=leng,
    data=f,
  )
component.resources.append(
  ocm.Resource(
    name='${asset.name}',
    version=version_str,
    type='${asset.artefact_type}',
    access=ocm.LocalBlobAccess(
      mediaType='application/gzip',
      localReference=digest,
      size=leng,
    ),
    extraIdentity=${asset.artefact_extra_id},
    labels=${asset.ocm_labels},
    srcRefs=[{
      'identitySelector': main_source_ref,
    },]
  ),
)
% elif isinstance(asset, BuildstepFileAsset):
step_output_dir = '${asset.step_output_dir}'
if not (matching_files := glob.glob(f'{step_output_dir}/${asset.path}')):
  print('Error: no files matched ${asset.path}')
  exit(1)

%  if asset.mode is FileAssetMode.TAR:
# no need to use ctx-mgr - process is short-lived + we keep sole handle
blobfh = tempfile.TemporaryFile()
tf = tarfile.open(mode='w:xz', fileobj=blobfh)
for f in matching_files:
  logger.info(f'adding {f} to tarchive')
  tf.add(
    name=f,
%    if asset.prefix:
    arcname=f.removeprefix(step_output_dir + '/').removeprefix('${asset.prefix}'),
%    else:
    arcname=f.removeprefix(step_output_dir + '/'),
%    endif
  )
tf.close()
blobfh.flush()
leng = blobfh.tell()

blob_mimetype = 'application/x-xz+tar'

%  elif asset.mode is FileAssetMode.SINGLE_FILE:
if not len(matching_files) == 1:
  logger.error(f'expected single file, but found: {matching_files}')
  exit(1)
asset_path = matching_files[0]
blob_mimetype = magic.detect_from_filename(asset_path).mime_type
blobfh = open(asset_path, 'rb')
leng = os.stat(asset_path).st_size
%  endif
blobfh.seek(0)

hash = hashlib.sha256()
while (chunk := blobfh.read(4096)):
  hash.update(chunk)
blobfh.seek(0)

digest = f'sha256:{hash.hexdigest()}'
oci_client.put_blob(
  image_reference=component_descriptor_target_ref,
  digest=digest,
  octets_count=leng,
  data=blobfh,
)
component.resources.append(
  ocm.Resource(
    name='${asset.name}',
    version=version_str,
    type='${asset.artefact_type}',
    access=ocm.LocalBlobAccess(
      mediaType=blob_mimetype,
      localReference=digest,
      size=leng,
    ),
    extraIdentity=${asset.artefact_extra_id},
    labels=${asset.ocm_labels},
  ),
)
%  if asset.upload_as_github_asset:
blobfh.seek(0)
github_assets.append({
  'fh': blobfh,
  'name': '${github_asset_name(asset)}',
  'mimetype': blob_mimetype,
})
%  endif

% else:
  <% raise ValueError(asset) %>
% endif
% endfor
% endif

% if release_commit_callback_image_reference:
release_commit_callback_image_reference = '${release_commit_callback_image_reference}'
% else:
release_commit_callback_image_reference = None
% endif

version_interface = VersionInterface('${version_trait.version_interface().value}')
% if version_interface is VersionInterface.FILE:
version_path = '${os.path.join(repo.resource_name(), version_trait.versionfile_relpath())}'
% elif version_interface is VersionInterface.CALLBACK:
version_path = '${os.path.join(repo.resource_name(), version_trait.write_callback())}'
% else:
  <% raise ValueError('not implemented', version_interface) %>
% endif

print(f'{version_path=}')
print(f'{version_interface=}')

git_helper = gitutil.GitHelper(
  repo=repo_dir,
  git_cfg=github_cfg.git_cfg(
    repo_path=f'{repo_owner}/{repo_name}',
  ),
)
branch = repository_branch
repository = github_api.repository(
  repo_owner,
  repo_name,
)

% if release_trait.rebase_before_release():
logger.info(f'will fetch and rebase refs/heads/{branch}')
upstream_commit_sha = git_helper.fetch_head(
    f'refs/heads/{branch}'
).hexsha
git_helper.rebase(commit_ish=upstream_commit_sha)
% endif

% if create_release_commit:
release_commit = create_release_commit(
  git_helper=git_helper,
  branch=branch,
  version=version_str,
  version_interface=version_interface,
  version_path=version_path,
%   if release_commit_message_prefix:
  release_commit_message_prefix='${release_commit_message_prefix}',
%   endif
%   if release_callback_path:
  release_commit_callback='${release_callback_path}',
  release_commit_callback_image_reference=release_commit_callback_image_reference,
%   endif
)

%   if push_release_commit:
git_helper.push(
  from_ref=release_commit.hexsha,
  to_ref=branch,
)
%   endif

tags = _calculate_tags(
  version=version_str,
  github_release_tag=${github_release_tag},
  git_tags=${git_tags},
)

if have_tag_conflicts(
  repository=repository,
  tags=tags,
):
  exit(1)

create_and_push_tags(
  git_helper=git_helper,
  tags=tags,
  release_commit=release_commit,
)
% endif

logger.info('validating component-descriptor')
nodes = cnudie.iter.iter(
  component=component,
  lookup=component_descriptor_lookup,
)
for validation_error in cnudie.validate.iter_violations(
  nodes=nodes,
  oci_client=oci_client,
):
  logger.warning(f'{validation_error=}')

% if process_release_notes:
release_notes_md = None
try:
  release_notes_md = collect_release_notes(
    git_helper=git_helper,
    release_version=version_str,
    component=component,
    component_descriptor_lookup=component_descriptor_lookup,
    version_lookup=version_lookup,
  )
  git_helper.push('refs/notes/commits', 'refs/notes/commits')
except:
  logger.warning('an error occurred whilst trying to collect release-notes')
  logger.warning('release will continue')
  traceback.print_exc()
% else:
release_notes_md = None
% endif

tgt_ref = cnudie.util.target_oci_ref(component=component)

if release_notes_md:
  release_notes_octets = release_notes_md.encode('utf-8')
  release_notes_digest = f'sha256:{hashlib.sha256(release_notes_octets).hexdigest()}'
  oci_client.put_blob(
    image_reference=tgt_ref,
    digest=release_notes_digest,
    octets_count=len(release_notes_octets),
    data=release_notes_octets,
  )

  component.resources.append(
    ocm.Resource(
      name=release_notes.ocm.release_notes_resource_name,
      version=component.version,
      type='text/markdown.release-notes',
      access=ocm.LocalBlobAccess(
        localReference=release_notes_digest,
        size=len(release_notes_octets),
        mediaType='text/markdown.release-notes',
      ),
    ),
  )
  logger.info('added release-notes to component-descriptor:')
  logger.info(f'{component.resources[-1]}')

logger.info(f'publishing OCM-Component-Descriptor to {tgt_ref=}')
uploaded_oci_manifest_bytes = ocm.upload.upload_component_descriptor(
  component_descriptor=component_descriptor,
  oci_client=oci_client,
)

% if release_trait.release_on_github():
try:
  for releases, succeeded in github.release.delete_outdated_draft_releases(repository):
    if succeeded:
      logger.info(f'deleted {release.name=}')
    else:
      logger.warn(f'failed to delete {release.name=}')
except:
  logger.warning('An Error occurred whilst trying to remove draft-releases')
  traceback.print_exc()
  # keep going

try:
  print(f'{uploaded_oci_manifest_bytes=}')
except:
  pass

release_tag = tags[0].removeprefix('refs/tags/')
draft_tag = f'{version_str}-draft'

if release_notes_md is not None:
  release_notes_md, is_full_release_notes  = github.release.body_or_replacement(
    body=release_notes_md,
  )
else:
  is_full_release_notes = False


gh_release = github.release.find_draft_release(
  repository=repository,
  name=draft_tag,
)
if not gh_release:
  gh_release = repository.create_release(
    tag_name=release_tag,
    body=release_notes_md or '',
    draft=False,
    prerelease=False,
  )
else:
  gh_release.edit(
    tag_name=release_tag,
    name=release_tag,
    body=release_notes_md or '',
    draft=False,
    prerelease=False,
  )

if release_notes_md is not None and not is_full_release_notes:
  gh_release.upload_asset(
    content_type='application/markdown',
    name='release-notes.md',
    asset=release_notes_md.encode('utf-8'),
    label='Release Notes',
  )

upload_component_descriptor_as_release_asset(
  github_release=gh_release,
  component=component,
)
%   if assets:
for gh_asset in github_assets:
  logger.info(f'uploading {gh_asset=}')
  gh_release.upload_asset(
    content_type=gh_asset['mimetype'],
    name=gh_asset['name'],
    asset=gh_asset['fh'],
  )
%   endif
% endif

% if merge_back:
try:
  old_head = git_helper.repo.head

  create_and_push_mergeback_commit(
    git_helper=git_helper,
    tags=tags,
    branch=branch,
    merge_commit_message_prefix='${mergeback_commit_msg_prefix or ''}',
    release_commit=release_commit,
  )
except git.GitCommandError:
  # do not fail release upon mergeback-errors; tags have already been pushed. Missing merge-back
  # will only cause bump-commit to not be merged back to default branch (which is okay-ish)
  logger.warning(f'pushing of mergeback-commit failed; release continues, you need to bump manually')
  traceback.print_exc()
  git_helper.repo.head.reset(
    commit=old_head.commit,
    index=True,
    working_tree=True,
  )
% endif


% if version_operation != version.NOOP and bump_commit:
create_and_push_bump_commit(
  git_helper=git_helper,
  repo_dir=repo_dir,
  release_version=version_str,
  release_commit=release_commit,
  merge_release_back_to_default_branch_commit='HEAD',
  version_interface=version_interface,
  version_path=version_path,
  repository_branch=branch,
  version_operation='${version_operation}',
  prerelease_suffix='dev',
  publishing_policy=concourse.model.traits.release.ReleaseCommitPublishingPolicy(
    '${release_trait.release_commit_publishing_policy().value}'
  ),
  commit_message_prefix='${next_cycle_commit_message_prefix or ''}',
  % if next_version_callback_path:
  next_version_callback='${next_version_callback_path}',
  % endif
)
% endif

% if has_slack_trait:
  % for slack_channel_cfg in slack_channel_cfgs:
try:
  if release_notes_md:
    post_to_slack(
      release_notes_markdown=release_notes_md,
      component=component,
      slack_cfg_name='${slack_channel_cfg["slack_cfg_name"]}',
      slack_channel='${slack_channel_cfg["channel_name"]}',
    )
except:
  logger.warning('An error occurred whilst trying to post release-notes to slack')
  traceback.print_exc()
  % endfor
% endif

% if post_release_callback_path:
_invoke_callback(
  repo_dir=git_helper.repo.working_tree_dir,
  effective_version=version_str,
  callback_script_path='${post_release_callback_path}',
)
% endif
</%def>
