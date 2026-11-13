import Engine
import SwiftUI

struct SearchView: View {
    var body: some View {
        Page(title: "Job search", subtitle: "Which jobs to look for on LinkedIn, and which to leave alone.") {
            SearchForm()
            FiltersCard()
        }
    }
}

/// Job titles, place and kind of work (shared with onboarding).
struct SearchForm: View {
    @Environment(AppModel.self) private var model
    var compact = false

    var body: some View {
        @Bindable var model = model
        let s = $model.settings.search
        VStack(alignment: .leading, spacing: 16) {
            Card {
                VStack(alignment: .leading, spacing: 18) {
                    Field(label: "Job titles to search for", hint: "Press Return after each one. Each title is its own LinkedIn search.") {
                        TagEditor(tags: s.keywords, placeholder: "e.g. Marketing Coordinator", suggestions: titleIdeas)
                    }
                    Field(label: "Where", hint: "A city, a state, or a country.") { TextInput("United States", text: s.location) }
                    Field(label: "Kind of workplace") {
                        ChipPicker(options: WorkplaceType.allCases, selection: s.workplace, title: \.rawValue)
                    }
                    Field(label: "Experience level", hint: "Leave all off to see every level.", optional: true) {
                        ChipPicker(options: ExperienceLevel.allCases, selection: s.levels, title: \.rawValue)
                    }
                    Field(label: "Posted") {
                        Segmented(options: DatePosted.allCases, selection: s.datePosted, title: \.label).frame(maxWidth: 480)
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    ToggleRow(title: "Also apply on company websites",
                              detail: "Off: only LinkedIn “Easy Apply” jobs, which are the quickest and most reliable. On: also jobs that send you to the company's own site (Greenhouse, Lever, Workday and others). Some of those need a code from your email.",
                              isOn: s.includeExternal)
                    if !compact {
                        Divider().overlay(Palette.line)
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Applications per run").font(Typo.bodyStrong)
                                Text("It stops after this many. Start small while you check its work.").font(Typo.small).foregroundStyle(Palette.textSoft)
                            }
                            Spacer()
                            Stepper(value: $model.settings.limits.maxAppliesPerRun, in: 1...50) {
                                Text("\(model.settings.limits.maxAppliesPerRun)").font(Typo.number(15)).frame(minWidth: 28)
                            }
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Result pages per title").font(Typo.bodyStrong)
                                Text("Each page has 25 jobs.").font(Typo.small).foregroundStyle(Palette.textSoft)
                            }
                            Spacer()
                            Stepper(value: s.maxPages, in: 1...10) {
                                Text("\(model.settings.search.maxPages)").font(Typo.number(15)).frame(minWidth: 28)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Titles suggested from the user's own job history.
    private var titleIdeas: [String] {
        var seen = Set<String>()
        return model.profile.workHistory.map(\.title).map(\.trimmed).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

struct FiltersCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let f = $model.settings.filters
        Card {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle(title: "Leave these alone", detail: "Jobs that match are skipped without opening them.")
                Field(label: "Companies to skip", hint: "For example your current employer.", optional: true) {
                    TagEditor(tags: f.blacklistCompanies, placeholder: "Company name")
                }
                Field(label: "Skip titles containing", hint: "For example Senior, Intern, Manager.", optional: true) {
                    TagEditor(tags: f.titleExclude, placeholder: "A word")
                }
                Field(label: "Only titles containing", hint: "Leave empty to allow any title the search finds.", optional: true) {
                    TagEditor(tags: f.titleMustContain, placeholder: "A word")
                }
            }
        }
    }
}
