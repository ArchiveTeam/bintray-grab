# encoding=utf8
import datetime
from distutils.version import StrictVersion
import hashlib
import os.path
import random
from seesaw.config import realize, NumberConfigValue
from seesaw.externalprocess import ExternalProcess
from seesaw.item import ItemInterpolation, ItemValue
from seesaw.task import SimpleTask, LimitConcurrent
from seesaw.tracker import GetItemFromTracker, PrepareStatsForTracker, \
    UploadWithTracker, SendDoneToTracker
import shutil
import socket
import subprocess
import sys
import time
import string

import seesaw
from seesaw.externalprocess import WgetDownload
from seesaw.pipeline import Pipeline
from seesaw.project import Project
from seesaw.util import find_executable

if StrictVersion(seesaw.__version__) < StrictVersion('0.8.5'):
    raise Exception('This pipeline needs seesaw version 0.8.5 or higher.')


###########################################################################
# Find a useful Wget+Lua executable.
#
# WGET_AT will be set to the first path that
# 1. does not crash with --version, and
# 2. prints the required version string

WGET_AT = find_executable(
    'Wget+AT',
    [
        'GNU Wget 1.20.3-at.20210504.01'
    ],
    [
        './wget-at',
        '/home/warrior/data/wget-at'
    ]
)

if not WGET_AT:
    raise Exception('No usable Wget+At found.')


###########################################################################
# The version number of this pipeline definition.
#
# Update this each time you make a non-cosmetic change.
# It will be added to the WARC files and reported to the tracker.
VERSION = '20210517.01'
USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/70.0.3538.77 Safari/537.36'
TRACKER_ID = 'bintray'
TRACKER_HOST = 'legacy-api.arpa.li'
MULTI_ITEM_SIZE = 1


###########################################################################
# This section defines project-specific tasks.
#
# Simple tasks (tasks that do not need any concurrency) are based on the
# SimpleTask class and have a process(item) method that is called for
# each item.
class CheckIP(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'CheckIP')
        self._counter = 0

    def process(self, item):
        # NEW for 2014! Check if we are behind firewall/proxy

        if self._counter <= 0:
            item.log_output('Checking IP address.')
            ip_set = set()

            ip_set.add(socket.gethostbyname('twitter.com'))
            ip_set.add(socket.gethostbyname('facebook.com'))
            ip_set.add(socket.gethostbyname('youtube.com'))
            ip_set.add(socket.gethostbyname('microsoft.com'))
            ip_set.add(socket.gethostbyname('icanhas.cheezburger.com'))
            ip_set.add(socket.gethostbyname('archiveteam.org'))

            if len(ip_set) != 6:
                item.log_output('Got IP addresses: {0}'.format(ip_set))
                item.log_output(
                    'Are you behind a firewall/proxy? That is a big no-no!')
                raise Exception(
                    'Are you behind a firewall/proxy? That is a big no-no!')

        # Check only occasionally
        if self._counter <= 0:
            self._counter = 10
        else:
            self._counter -= 1


class PrepareDirectories(SimpleTask):
    def __init__(self, warc_prefix):
        SimpleTask.__init__(self, 'PrepareDirectories')
        self.warc_prefix = warc_prefix

    def process(self, item):
        item_name = item['item_name']
        item_name_hash = hashlib.sha1(item_name.encode('utf8')).hexdigest()
        escaped_item_name = item_name_hash
        dirname = '/'.join((item['data_dir'], escaped_item_name))

        if os.path.isdir(dirname):
            shutil.rmtree(dirname)

        os.makedirs(dirname)

        item['item_dir'] = dirname
        item['warc_file_base'] = '-'.join([
            self.warc_prefix,
            item_name_hash,
            time.strftime('%Y%m%d-%H%M%S')
        ])

        open('%(item_dir)s/%(warc_file_base)s.warc.gz' % item, 'w').close()
        open('%(item_dir)s/%(warc_file_base)s_data.txt' % item, 'w').close()


class MoveFiles(SimpleTask):
    def __init__(self):
        SimpleTask.__init__(self, 'MoveFiles')

    def process(self, item):
        os.rename('%(item_dir)s/%(warc_file_base)s.warc.gz' % item,
            '%(data_dir)s/%(warc_file_base)s.warc.gz' % item)
        os.rename('%(item_dir)s/%(warc_file_base)s_data.txt' % item,
            '%(data_dir)s/%(warc_file_base)s_data.txt' % item)

        shutil.rmtree('%(item_dir)s' % item)

def get_hash(filename):
    with open(filename, 'rb') as in_file:
        return hashlib.sha1(in_file.read()).hexdigest()

class MaybeSendDoneToTracker(SendDoneToTracker):
    def enqueue(self, item):
        if len(item['item_name']) == 0:
            return self.complete_item(item)
        return super(MaybeSendDoneToTracker, self).enqueue(item)

CWD = os.getcwd()
PIPELINE_SHA1 = get_hash(os.path.join(CWD, 'pipeline.py'))
LUA_SHA1 = get_hash(os.path.join(CWD, 'bintray.lua'))

def stats_id_function(item):
    d = {
        'pipeline_hash': PIPELINE_SHA1,
        'lua_hash': LUA_SHA1,
        'python_version': sys.version,
    }

    return d


class WgetArgs(object):
    def realize(self, item):
        wget_args = [
            WGET_AT,
            '-U', USER_AGENT,
            '-nv',
            '--content-on-error',
            '--load-cookies', 'cookies.txt',
            '--lua-script', 'bintray.lua',
            '-o', ItemInterpolation('%(item_dir)s/wget.log'),
            '--no-check-certificate',
            '--output-document', ItemInterpolation('%(item_dir)s/wget.tmp'),
            '--truncate-output',
            '-e', 'robots=off',
            '--rotate-dns',
            '--recursive', '--level=inf',
            '--no-iri',
            '--no-parent',
            '--page-requisites',
            '--timeout', '120',
            '--tries', 'inf',
            '--domains', 'voat.co',
            '--span-hosts',
            '--waitretry', '30',
            '--warc-file', ItemInterpolation('%(item_dir)s/%(warc_file_base)s'),
            '--warc-header', 'operator: Archive Team',
            '--warc-header', 'x-wget-at-project-version: ' + VERSION,
            '--warc-header', 'x-wget-at-project-name: ' + TRACKER_ID,
            '--warc-dedup-url-agnostic'
        ]
        
        item_names = item['item_name'].split('\0')
        item['item_name_newline'] = item['item_name'].replace('\0', '\n')

        item_names_to_submit = item_names.copy()
        for item_name in item_names:
            wget_args.extend(['--warc-header', 'x-wget-at-project-item-name: '+item_name])
            wget_args.append('item-name://' + item_name)
            if item_name.startswith("http"):
                wget_args.extend(['--warc-header', 'bintray-file-hack: ' + item_name])
                wget_args.append(item_name.split("?", 1)[0] + "?expiry=1619896591447&signature=hC0rtVP5nyrbSJkj8OTC62Q%2FKESWeQH17LdtS%2BupwKTfgXWKgq0y6bQSB9iS0d2QXPkoBaqbggr%2B5L9tiP27MQ%3D")
            else:
                item_type, item_value = item_name.split(':', 1)
                if item_type == 'user':
                    wget_args.extend(['--warc-header', 'bintray-user: ' + item_value])
                    wget_args.append(f'https://bintray.com/{item_value}')
                    wget_args.append(f'https://bintray.com/{item_value}/')
                elif item_type == 'file':
                    wget_args.extend(['--warc-header', 'bintray-file: ' + item_value])
                    assert item_value.startswith("http"), "If this fails, something strange has happened"
                    wget_args.append(item_value.split("#", 1)[0]) # Strip off fragment to not confuse w/ fileretry
                elif item_type == 'cdn':
                    # Format: cdn:len.len.serial.[urls]
                    wget_args.extend(['--warc-header', 'bintray-cdn: ' + item_value])
                    [len1, len2, serial, addr] = item_value.split('.', 3)
                    assert int(len1) + int(len2) == len(addr)
                    url_to_do = addr[0:int(len1)]
                    url_to_do = url_to_do.split("#", 1)[0] # Remove fragment
                    orig_url = addr[int(len1):int(len1) + int(len2)]
                    wget_args.append(url_to_do + "#" + serial + "#" + orig_url)
                    wget_args.remove("--page-requisites") # Gets rid of fragment when present for some reason
                    wget_args.remove("--no-check-certificate")
                    wget_args.remove("--recursive")
                    wget_args.remove("--level=inf")

                    wget_args.remove("--lua-script")
                    wget_args.remove("bintray.lua")
                    wget_args.extend(["--lua-script", "bintray_noge.lua"])
                    assert len(item_names) == 1
                    #print("WGE is " + wget_args[-1])
                elif item_type == 'fileretry':
                    # Format: fileretry:url#serial (serial in fragment)
                    wget_args.extend(['--warc-header', 'bintray-fileretry: ' + item_value])
                    wget_args.append(item_value)
                    wget_args.remove("--page-requisites")
                    wget_args.remove("--no-check-certificate")
                    wget_args.remove("--recursive")
                    wget_args.remove("--level=inf")

                    wget_args.remove("--lua-script")
                    wget_args.remove("bintray.lua")
                    wget_args.extend(["--lua-script", "bintray_noge.lua"])
                    assert len(item_names) == 1
                else:
                    raise ValueError('item_type not supported.')

        if 'bind_address' in globals():
            wget_args.extend(['--bind-address', globals()['bind_address']])
            print('')
            print('*** Wget will bind address at {0} ***'.format(
                globals()['bind_address']))
            print('')

        return realize(wget_args, item)

###########################################################################
# Initialize the project.
#
# This will be shown in the warrior management panel. The logo should not
# be too big. The deadline is optional.
project = Project(
    title = 'bintray',
    project_html = '''
    <img class="project-logo" alt="logo" src="https://wiki.archiveteam.org/images/Archiveteamsmall.png?959ea" height="50px"/>
    <h2>Bintray <span class="links"><a href="https://bintray.com/">Website</a> &middot; <a href="http://tracker.archiveteam.org/bintray/">Leaderboard</a></span></h2>
    ''',)

pipeline = Pipeline(
    CheckIP(),
    GetItemFromTracker('http://{}/{}/multi={}/'
        .format(TRACKER_HOST, TRACKER_ID, MULTI_ITEM_SIZE),
        downloader, VERSION),
    PrepareDirectories(warc_prefix='bintray'),
    WgetDownload(
        WgetArgs(),
        max_tries=1,
        accept_on_exit_code=[0, 4, 8],
        env={
            'item_dir': ItemValue('item_dir'),
            'warc_file_base': ItemValue('warc_file_base'),
            'item_name_newline': ItemValue('item_name_newline'),
        }
    ),
    PrepareStatsForTracker(
        defaults={'downloader': downloader, 'version': VERSION},
        file_groups={
            'data': [
                ItemInterpolation('%(item_dir)s/%(warc_file_base)s.warc.gz')
            ]
        },
        id_function=stats_id_function,
    ),
    MoveFiles(),
    LimitConcurrent(NumberConfigValue(min=1, max=20, default='2',
        name='shared:rsync_threads', title='Rsync threads',
        description='The maximum number of concurrent uploads.'),
        UploadWithTracker(
            'http://%s/%s' % (TRACKER_HOST, TRACKER_ID),
            downloader=downloader,
            version=VERSION,
            files=[
                ItemInterpolation('%(data_dir)s/%(warc_file_base)s.warc.gz'),
                ItemInterpolation('%(data_dir)s/%(warc_file_base)s_data.txt')
            ],
            rsync_target_source_path=ItemInterpolation('%(data_dir)s/'),
            rsync_extra_args=[
                '--recursive',
                '--partial',
                '--partial-dir', '.rsync-tmp',
                '--min-size', '1',
                '--no-compress',
                '--compress-level', '0'
            ]
        ),
    ),
    MaybeSendDoneToTracker(
        tracker_url='https://%s/%s' % (TRACKER_HOST, TRACKER_ID),
        stats=ItemValue('stats')
    )
)
