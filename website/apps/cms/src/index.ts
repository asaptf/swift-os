import type { Core } from '@strapi/strapi';
import * as seed from './seed-data';

const SINGLES = ['home', 'live-proof', 'status-page', 'quickstart-page'];
const COLLECTIONS = ['capability', 'roadmap-item', 'glossary-term', 'article', 'faq'];

async function grantPublicRead(strapi: Core.Strapi) {
	const role = await strapi.db
		.query('plugin::users-permissions.role')
		.findOne({ where: { type: 'public' } });
	if (!role) return;

	const wanted: string[] = [
		...SINGLES.map((a) => `api::${a}.${a}.find`),
		...COLLECTIONS.flatMap((a) => [`api::${a}.${a}.find`, `api::${a}.${a}.findOne`])
	];

	for (const action of wanted) {
		const exists = await strapi.db
			.query('plugin::users-permissions.permission')
			.findOne({ where: { action, role: role.id } });
		if (!exists) {
			await strapi.db
				.query('plugin::users-permissions.permission')
				.create({ data: { action, role: role.id } });
		}
	}
}

async function seedSingle(strapi: Core.Strapi, uid: string, data: Record<string, unknown>) {
	const existing = await strapi.documents(uid as never).findFirst();
	if (existing) return;
	await strapi.documents(uid as never).create({ data } as never);
	strapi.log.info(`[seed] created single ${uid}`);
}

async function seedCollection(strapi: Core.Strapi, uid: string, rows: Record<string, unknown>[]) {
	const existing = await strapi.documents(uid as never).findMany({ limit: 1 } as never);
	if (Array.isArray(existing) && existing.length > 0) return;
	for (const data of rows) await strapi.documents(uid as never).create({ data } as never);
	strapi.log.info(`[seed] created ${rows.length} ${uid}`);
}

export default {
	register() {},

	async bootstrap({ strapi }: { strapi: Core.Strapi }) {
		try {
			await seedSingle(strapi, 'api::home.home', seed.home);
			await seedSingle(strapi, 'api::live-proof.live-proof', seed.liveProof);
			await seedSingle(strapi, 'api::status-page.status-page', seed.statusPage);
			await seedSingle(strapi, 'api::quickstart-page.quickstart-page', seed.quickstartPage);

			await seedCollection(strapi, 'api::capability.capability', seed.capabilities);
			await seedCollection(strapi, 'api::roadmap-item.roadmap-item', seed.roadmapItems);
			await seedCollection(strapi, 'api::glossary-term.glossary-term', seed.glossaryTerms);
			await seedCollection(strapi, 'api::faq.faq', seed.faqs);
			await seedCollection(strapi, 'api::article.article', seed.articles);

			await grantPublicRead(strapi);
			strapi.log.info('[seed] swift-os content ready · public read enabled');
		} catch (err) {
			strapi.log.error('[seed] failed: ' + (err as Error).message);
		}
	}
};
