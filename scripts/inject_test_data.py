# The contents of this file are subject to the Common Public Attribution
# License Version 1.0. (the "License"); you may not use this file except in
# compliance with the License. You may obtain a copy of the License at
# http://code.reddit.com/LICENSE. The License is based on the Mozilla Public
# License Version 1.1, but Sections 14 and 15 have been added to cover use of
# software over a computer network and provide for limited attribution for the
# Original Developer. In addition, Exhibit A has been modified to be consistent
# with Exhibit B.
#
# Software distributed under the License is distributed on an "AS IS" basis,
# WITHOUT WARRANTY OF ANY KIND, either express or implied. See the License for
# the specific language governing rights and limitations under the License.
#
# The Original Code is reddit.
#
# The Original Developer is the Initial Developer.  The Initial Developer of
# the Original Code is reddit Inc.
#
# All portions of the code written by reddit are Copyright (c) 2006-2015 reddit
# Inc. All Rights Reserved.
###############################################################################

from __future__ import division

import collections
import HTMLParser
import itertools
import random
import string
import time

import requests

from pylons import app_globals as g

from r2.lib.db import queries
from r2.lib import amqp
from r2.lib.utils import weighted_lottery, get_requests_resp_json
from r2.lib.voting import cast_vote
from r2.models import (
    Account,
    NotFound,
    register,
    Subreddit,
)


def ensure_account(name):
    """Look up or register an account and return it."""
    try:
        account = Account._by_name(name)
        print ">> found /u/{}".format(name)
        return account
    except NotFound:
        print ">> registering /u/{}".format(name)
        return register(name, "password", "127.0.0.1")


def ensure_subreddit(name, author):
    """Look up or create a subreddit and return it."""
    try:
        sr = Subreddit._by_name(name)
        print ">> found /r/{}".format(name)
        return sr
    except NotFound:
        print ">> creating /r/{}".format(name)
        sr = Subreddit._new(
            name=name,
            title="/r/{}".format(name),
            author_id=author._id,
            lang="en",
            ip="127.0.0.1",
        )
        sr._commit()
        return sr


def inject_test_data(num_links=25, num_comments=25, num_votes=5):
    """Flood your reddit install with test data based on reddit.com."""

    print ">>>> Ensuring configured objects exist"
    system_user = ensure_account(g.system_user)
    ensure_account(g.automoderator_account)
    ensure_subreddit(g.default_sr, system_user)
    ensure_subreddit(g.takedown_sr, system_user)
    ensure_subreddit(g.beta_sr, system_user)
    ensure_subreddit(g.promo_sr_name, system_user)

    amqp.worker.join()
