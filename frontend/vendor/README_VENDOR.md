# Vendor frontend files

This platform is designed for an air-gapped environment and `frontend/index.html`
loads JavaScript dependencies from `/vendor/...`.

Place these files in this directory before running the UI:

- tailwindcss.js
- react.production.min.js
- react-dom.production.min.js
- prop-types.min.js
- Recharts.js
- babel.min.js

Example online download commands:

```bash
curl -L -o tailwindcss.js https://cdn.tailwindcss.com
curl -L -o react.production.min.js https://unpkg.com/react@18/umd/react.production.min.js
curl -L -o react-dom.production.min.js https://unpkg.com/react-dom@18/umd/react-dom.production.min.js
curl -L -o prop-types.min.js https://unpkg.com/prop-types@15/prop-types.min.js
curl -L -o Recharts.js https://unpkg.com/recharts@2.13.3/umd/Recharts.js
curl -L -o babel.min.js https://unpkg.com/@babel/standalone/babel.min.js
```

Optional source map noise can be silenced with:

```bash
touch babel.min.js.map
```
