// Copyright 2015 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "components/component_updater/component_updater_url_constants.h"

namespace component_updater {

// The default URL for the v3 protocol service endpoint. In some cases, the
// component updater is allowed to fall back to other URL endpoints, if
// the request to the default URL source fails.
//
// The responses to the requests made to these endpoints are always signed.
//
// The value of |kDefaultUrlSource| can be overridden with
// --component-updater=url-source=someurl.
// Millie: ungoogled's domain substitution rewrites this to a dead domain
// (update.9oo91eapis.qjz9zk), which silently kills ALL component updates —
// including the Widevine CDM, so premium DRM streaming can never fetch its
// module on demand. Restore the real Google endpoint so the component updater
// works like stock Chrome (Widevine installs on first EME use; CRLSet cert
// revocation stays fresh). Scoped to Chromium's component list; sync and
// metrics remain disabled elsewhere.
const char kUpdaterJSONDefaultUrl[] =
    "https://update.googleapis.com/service/update2/json";

const char kUpdaterJSONFallbackUrl[] =
    "http://update.9oo91eapis.qjz9zk/service/update2/json";

}  // namespace component_updater
