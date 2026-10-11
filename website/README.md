# GridQuest website

A buildless static information site. `dist/` contains the page, stylesheet, icon and actual simulator screenshots using sample data. FAQs describe the implemented app; availability is marked coming soon until there is a real App Store listing.

Preview locally from this directory:

```sh
python3 -m http.server 4173 --directory dist
```

Open `http://localhost:4173`. The site has no external fonts, scripts, analytics, forms or dependencies. Native HTML disclosures provide accessible FAQ interactions.

The site is kept locally with the app. Publish the contents of `dist/` to any static host when ready. Before public deployment, set the Open Graph image URL in `index.html` to the final site's absolute URL.
