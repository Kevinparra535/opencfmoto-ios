// SPDX-License-Identifier: AGPL-3.0-or-later
// WAVE-2 PLACEHOLDER — owner: ui-main. Replace the body; keep the type name `AboutScreen` and its
// no-argument init (other screens link to it). Do not wrap it in a NavigationStack (RootView owns
// the stack); read the model with `@Environment(AppModel.self)`.

import SwiftUI
import OpenCfMotoAppModel

struct AboutScreen: View {
    var body: some View {
        Text(verbatim: "AboutScreen")
    }
}
