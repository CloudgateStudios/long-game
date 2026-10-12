<p align="center"><img src="Design/logo-mark.svg" width="120" alt="Long Game icon"></p>

# Long Game

A personal training app for iPhone, iPad and Mac. You set a goal, it holds your training
plan, reads your completed workouts and recovery data from Apple Health, shows how what you
did compares with what you planned, and uses Claude as a coach to review your training and
propose changes.

It is a single-user app with no backend. Your data stays in Apple Health, on your devices,
and in your own private iCloud database. The only thing that leaves is the summary sent to
the Claude API when you ask the coach for something, and the app shows you exactly what
that is.

> Long Game is a training assistant, not a medical service. For pain, illness or readings
> that worry you, see a professional.

## What it does

- **Plan** – build a training plan by hand, or have the coach interview you and draft one.
  Week and month calendar views; sessions can be edited, moved and deleted. A plan can be
  shared or saved as a PDF calendar, one month to a page.
- **Track** – workouts from Apple Health are matched to planned sessions and marked done,
  partly done, overdone, missed or unplanned. The same session recorded by two devices
  (a watch and a bike computer, say) is counted once.
- **Trends** – training load from heart-rate zones or cycling power, a 7-day against 28-day
  load ratio, and HRV, resting heart rate and sleep against your own rolling baseline.
- **Coach** – a weekly or on-demand review with specific suggested changes, plus open
  conversation. Every suggestion is a before/after card that you accept or reject; nothing
  changes in your plan without you.

Swim, bike, run and strength are modelled; any other activity is logged and counts toward load.

## Requirements

- Xcode 27 or later, targeting iOS 27 and macOS 27
- A paid Apple Developer account (HealthKit and iCloud need one)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only if you change `project.yml`
- An [Anthropic API key](https://console.anthropic.com/) for the in-app coach. The
  "Copy for Claude" option works without one.

## Building

1. Copy `Config/Local.example.xcconfig` to `Config/Local.xcconfig` and fill in your team ID,
   a bundle identifier and an iCloud container name. That file is ignored by git.
2. Open `LongGame.xcodeproj` and let automatic signing register the identifiers.
3. Run the `LongGame` scheme.

In the simulator the app runs on bundled synthetic data in a separate store that never
syncs, with a sample plan and a stand-in coach, so everything can be tried without Health
data or a key. On a device, launch with `-fixture` to do the same in a debug build.

The iPhone is the device that reads Apple Health. iPad and Mac show what it has synced and
can edit the plan and talk to the coach.

## The coach and what it costs

The app calls the Claude API directly with a key you paste into Settings, stored in your
iCloud Keychain. API use is billed by Anthropic, separately from a Claude subscription. As a
rough guide on the default model: a review costs about 15 to 35 cents, a generated plan 30 to
60 cents, and a short conversation around 10 cents. Settings shows a running estimate.

What is sent: age (not date of birth), sex, height, weight, zones, goals, the plan, four
weeks of per-workout summaries with any effort rating and notes you added, 28 days of daily
recovery metrics, and load trends. Never
names, locations, device or app names, or raw sample streams. "See What Will Be Sent" shows
the exact payload before you send it, and every review keeps a copy of what it sent.

## iCloud

Sync uses SwiftData with a CloudKit private database. Builds run from Xcode use CloudKit's
Development environment by default; `LG_ICLOUD_ENVIRONMENT` in `Config/Shared.xcconfig`
switches to Production, which needs the schema deployed from the CloudKit Console first.
All your devices must use the same environment to see the same data.

### Deploying the schema to Production

Production only accepts additions. Once a record type or field is deployed it can never be
removed, renamed, given another type, or have its encryption changed, so settle the models
first. Then, before the first release and after every later model change:

1. Run a debug build from Xcode on a device signed in to iCloud, with the launch argument
   `-initializeCloudKitSchema` (Product > Scheme > Edit Scheme > Run > Arguments). This
   writes every record type and field to the Development schema, including optional fields
   no record has used yet, which CloudKit would otherwise leave out. The Xcode console
   prints the result. Remove the argument afterwards.
2. In the CloudKit Console, compare the Development schema with
   `Packages/LongGameKit/Sources/Models`, then choose Deploy Schema Changes.

If Development still holds a schema from before a field was encrypted, step 1 fails with
"invalid attempt to set value type ENCRYPTED_STRING". Reset the Development environment in the Console first. That erases the data
CloudKit holds for Development, so do it only when the copy on your devices is one you can
afford to lose or rebuild.

## TestFlight

Releases go to TestFlight through Xcode Cloud, which signs the builds itself, so no
certificates or keys are kept in this repository. The workflow is set up in Xcode or App
Store Connect, not in a file here. The one piece in the repository is
`ci_scripts/ci_post_clone.sh`, which writes `Config/Local.xcconfig` on the build machine
from the workflow's environment variables.

One-time setup:

1. Create the app in App Store Connect with your bundle identifier, for iOS and macOS.
2. Add an internal testing group and install TestFlight on each device.
3. Create a `release` branch. It marks what is on your devices: move it forward when you
   want to ship.
4. In Xcode, choose Integrate > Create Workflow and connect the repository. Give the
   workflow:
   - Environment variables `DEVELOPMENT_TEAM`, `LG_BUNDLE_ID` and `LG_ICLOUD_CONTAINER`,
     with the same values as your `Local.xcconfig`. Mark them as secret.
   - Start conditions on the `release` branch: on every change, and on a weekly schedule.
   - An Archive action for iOS and another for macOS, each with TestFlight (Internal
     Testing Only) distribution.
   - A TestFlight Internal Testing post-action for each archive, sent to your group.

TestFlight builds expire after 90 days. The weekly schedule rebuilds `release` so every
device always has a live build, without shipping unreleased work from `main`.

These builds use CloudKit Production. Deploy the schema (see iCloud above) before the
first release and again before moving `release` past a data model change.

## Project layout

```
LongGame/                 SwiftUI app: views, app state, resources
Packages/LongGameKit/
  Sources/Analysis/       Pure Swift rules: zones, load, baselines, matching, compliance
  Sources/Models/         SwiftData models and the store
  Sources/HealthIngest/   Everything that touches HealthKit, plus the synthetic fixture
  Sources/Coach/          Payload building, the Claude API client, reviews, chat, plans
  Tests/                  Swift Testing suites
Config/                   Build settings; your identifiers go in Local.xcconfig
Design/                   Icon and logo artwork (SVG)
Scripts/                  Fixture and icon generators
PROJECT_BRIEF.md          The original design brief
```

Tunable thresholds live in `Packages/LongGameKit/Sources/Analysis/AnalysisConstants.swift`.

## Tests

```bash
cd Packages/LongGameKit && swift test
```

The suite runs against a mocked API. A few tests call the real API with synthetic data and
cost money, so they only run when you supply a key:

```bash
cd Packages/LongGameKit && LONGGAME_LIVE_KEY=your-key swift test --filter LiveCoachTests
```

## Formatting and CI

Code is formatted with the `swift format` that ships with Xcode, using the rules in
`.swift-format`:

```bash
swift format format --in-place --recursive LongGame Packages
```

On every pull request GitHub Actions checks formatting, runs the tests and builds the app
for iOS and macOS. Pull request titles follow
[Conventional Commits](https://www.conventionalcommits.org/), for example
`fix: count a duplicated ride once`.

## Licence

MIT. See [LICENSE](LICENSE).
