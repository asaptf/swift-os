import type { Schema, Struct } from '@strapi/strapi';

export interface SharedCoverageStat extends Struct.ComponentSchema {
  collectionName: 'components_shared_coverage_stats';
  info: {
    displayName: 'Coverage stat';
    icon: 'chartCircle';
  };
  attributes: {
    accent: Schema.Attribute.Boolean & Schema.Attribute.DefaultTo<false>;
    decimals: Schema.Attribute.Integer & Schema.Attribute.DefaultTo<0>;
    label: Schema.Attribute.String;
    suffix: Schema.Attribute.String;
    to: Schema.Attribute.Decimal & Schema.Attribute.Required;
  };
}

export interface SharedFeature extends Struct.ComponentSchema {
  collectionName: 'components_shared_features';
  info: {
    displayName: 'Feature';
    icon: 'bulletList';
  };
  attributes: {
    bodyHtml: Schema.Attribute.Text;
    icon: Schema.Attribute.String;
    title: Schema.Attribute.String & Schema.Attribute.Required;
  };
}

export interface SharedNonGoal extends Struct.ComponentSchema {
  collectionName: 'components_shared_non_goals';
  info: {
    displayName: 'Non-goal';
    icon: 'crossCircle';
  };
  attributes: {
    body: Schema.Attribute.Text;
    title: Schema.Attribute.String & Schema.Attribute.Required;
  };
}

export interface SharedProofStat extends Struct.ComponentSchema {
  collectionName: 'components_shared_proof_stats';
  info: {
    displayName: 'Proof stat';
    icon: 'chartBubble';
  };
  attributes: {
    accent: Schema.Attribute.Boolean & Schema.Attribute.DefaultTo<false>;
    countTo: Schema.Attribute.Integer;
    label: Schema.Attribute.String & Schema.Attribute.Required;
    sub: Schema.Attribute.String;
    suffix: Schema.Attribute.String;
    uptimeSeconds: Schema.Attribute.Integer;
    value: Schema.Attribute.Text;
  };
}

export interface SharedStartCard extends Struct.ComponentSchema {
  collectionName: 'components_shared_start_cards';
  info: {
    displayName: 'Start card';
    icon: 'cursor';
  };
  attributes: {
    bodyHtml: Schema.Attribute.Text;
    href: Schema.Attribute.String;
    title: Schema.Attribute.String & Schema.Attribute.Required;
  };
}

export interface SharedWorksBadge extends Struct.ComponentSchema {
  collectionName: 'components_shared_works_badges';
  info: {
    displayName: 'Works badge';
    icon: 'dashboard';
  };
  attributes: {
    label: Schema.Attribute.String & Schema.Attribute.Required;
    variant: Schema.Attribute.Enumeration<
      ['ok', 'accent', 'warn', 'info', 'muted', 'err']
    > &
      Schema.Attribute.DefaultTo<'ok'>;
  };
}

declare module '@strapi/strapi' {
  export module Public {
    export interface ComponentSchemas {
      'shared.coverage-stat': SharedCoverageStat;
      'shared.feature': SharedFeature;
      'shared.non-goal': SharedNonGoal;
      'shared.proof-stat': SharedProofStat;
      'shared.start-card': SharedStartCard;
      'shared.works-badge': SharedWorksBadge;
    }
  }
}
