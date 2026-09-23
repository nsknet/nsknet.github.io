# SampleBlankSite

The minimal ASP.NET Core app NsPanel deploys when you create a **.NET Core site**.

`add_dotnet_site` (in `NsPanel/scripts/nginx.sh`) downloads
`https://nsknet.github.io/SampleBlankSite.tar` and renames every
`SampleBlankSite.*` file to the DLL name the operator chose.

That tarball is a build artifact of this project, committed at the repository
root so GitHub Pages serves it. Regenerate it after changing this project:

```bash
dotnet publish -c Release -o ./publish
tar -cf ../SampleBlankSite.tar -C ./publish .
```
