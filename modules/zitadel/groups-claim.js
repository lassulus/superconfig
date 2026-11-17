// Zitadel Action (Complement Token flow), run by name: the function name
// must stay the action's name in reconcile.py. Zitadel has put the roles of
// the requesting app's project, and only those, into this claim before
// the action runs; other projects' roles are under project-specific claims.
function groupsClaim(ctx, api) {
  var roles = ctx.v1.claims["urn:zitadel:iam:org:project:roles"];
  if (roles) {
    api.v1.claims.setClaim("groups", Object.keys(roles));
  }
}
