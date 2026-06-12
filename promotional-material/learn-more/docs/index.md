<!--
  Internal links below use base-relative paths (../../../../<route>) on purpose.
  This TechDoc is served at <app-base>/docs/default/system/learn-more, so four "../"
  steps land back at the app root in BOTH local dev (base "/") and the hosted demo
  (base "/tibco/hub"). TechDocs then intercepts the click and navigates the SPA.
  External https:// links automatically open in a new tab.
-->

# The TIBCO® Developer Hub

<!--
  The video is served by Caddy straight from the demo host (./media -> /srv/media),
  NOT by TechDocs, so we use an ABSOLUTE path. TechDocs rewrites *relative* asset
  URLs to its own storage API (which would 404 the video); absolute "/..." paths
  are left untouched. This URL only resolves on the hosted demo (base /tibco/hub);
  in local dev the video simply won't load, which is fine. See deploy/demo.
-->
<video controls preload="metadata" width="100%" style="max-width:880px;border-radius:8px;display:block;margin:1.5rem auto;">
  <source src="/tibco/hub/media/devhub-marketing.mp4" type="video/mp4">
  Your browser does not support embedded video.
</video>

Most development teams lose hours every week to the same problem: finding the assets
they need. APIs live in one place, documentation in another, and nobody is quite sure
which components already exist or who owns them. The TIBCO® Developer Hub brings all of
it together in a single portal, so your teams spend their time building instead of
searching.

It is built on Backstage, the open-source developer portal originally created at
Spotify and now used by hundreds of engineering organizations. On top of that
foundation, the Developer Hub adds first-class support for the TIBCO platform.

## Take a look around

This is a live environment, so feel free to click through it:

- [Catalog](../../../../catalog) — browse APIs, components, systems, and domains in one searchable inventory.
- [Topology](../../../../integration-topology) — see how your integration assets connect and depend on one another.
- [Marketplace](../../../../marketplace) — find ready-to-use assets and skills you can add in a click.
- [Docs](../../../../docs) — read documentation published right alongside each component.

## What it does for your teams

**Find what already exists.** A single catalog covers your APIs, applications,
templates, databases, EMS queues, and both TIBCO and non-TIBCO components. Developers
stop rebuilding things that are already there, and new joiners get up to speed in days
rather than weeks.

**Understand how everything fits together.** The integration topology maps the
relationships between flows, processes, APIs, and backend systems. Before you change a
component, you can see exactly what it touches.

**Start projects the right way.** Reusable templates carry your security and governance
standards with them, so a new BusinessWorks or Flogo project begins production-ready
instead of from a blank page.

**Bring in what you already have.** Import flows ingest your existing BW5, BW6/CE,
Flogo, and EMS estate and work out the relationships automatically, building a complete
picture of your landscape without manual documentation.

**Extend it to fit your world.** Because it is built on Backstage, the Developer Hub
works with the wider ecosystem of community plugins and adapts to the tools your teams
already rely on.

## Part of the TIBCO Platform

The Developer Hub is one piece of the broader TIBCO Platform, a unified foundation for
connecting, integrating, and managing your data and applications.

- [Watch the TIBCO Platform overview](https://www.youtube.com/watch?v=wVvnGU450J4&t=0)
- [Explore the TIBCO Platform](https://www.tibco.com/platform)

## Where to go next

- [Talk to us](https://www.tibco.com/contact-us) about your integration goals.
- [Explore the open-source repository](https://github.com/TIBCOSoftware/tibco-developer-hub) to see how the Developer Hub is built.
